package auth

import (
	"context"
	"os"
	"strings"

	enumspb "go.temporal.io/api/enums/v1"
	taskqueuepb "go.temporal.io/api/taskqueue/v1"
	"go.temporal.io/api/workflowservice/v1"
	"go.temporal.io/server/common/authorization"
	"go.temporal.io/server/common/log"
	"go.temporal.io/server/common/log/tag"
)

// customAuthorizer wraps the default Temporal authorizer and adds:
//  1. Task queue restrictions — workers can be blocked from polling specific task queues.
//  2. Any other custom rules you want to enforce (start workflow restrictions, etc.)
//
// Task queue restrictions are configured via the TEMPORAL_BLOCKED_TASK_QUEUES env var:
// a comma-separated list of task queue names that workers are not allowed to poll.
// Example: TEMPORAL_BLOCKED_TASK_QUEUES=InternalQueue,AdminOnlyQueue
type customAuthorizer struct {
	defaultAuthorizer    authorization.Authorizer
	blockedTaskQueues    map[string]struct{}
	logger               log.Logger
}

var _ authorization.Authorizer = (*customAuthorizer)(nil)

// NewCustomAuthorizer constructs the authorizer. It wraps the default authorizer
// so all standard Temporal permission checks still apply.
func NewCustomAuthorizer(logger log.Logger) authorization.Authorizer {
	blocked := make(map[string]struct{})
	if env := os.Getenv("TEMPORAL_BLOCKED_TASK_QUEUES"); env != "" {
		for _, tq := range strings.Split(env, ",") {
			tq = strings.TrimSpace(tq)
			if tq != "" {
				blocked[tq] = struct{}{}
				logger.Info("Task queue blocked from worker polling.", tag.WorkflowTaskQueueName(tq))
			}
		}
	}

	return &customAuthorizer{
		defaultAuthorizer: authorization.NewDefaultAuthorizer(),
		blockedTaskQueues: blocked,
		logger:            logger,
	}
}

func (a *customAuthorizer) Authorize(
	ctx context.Context,
	caller *authorization.Claims,
	target *authorization.CallTarget,
) (authorization.Result, error) {

	// Check task queue restrictions before delegating to the default authorizer.
	// Note: caller may be nil for health-check paths or when auth is bypassed.
	if deny, reason := a.checkTaskQueueRestrictions(target); deny {
		subject := ""
		if caller != nil {
			subject = caller.Subject
		}
		a.logger.Info("Task queue restriction applied.",
			tag.WorkflowNamespace(target.Namespace),
			tag.WorkflowTaskQueueName(extractTaskQueueName(target.Request)),
			tag.NewStringTag("api", target.APIName),
			tag.NewStringTag("subject", subject),
			tag.NewStringTag("reason", reason),
		)
		return authorization.Result{Decision: authorization.DecisionDeny}, nil
	}

	// Delegate everything else to the default authorizer.
	return a.defaultAuthorizer.Authorize(ctx, caller, target)
}

// checkTaskQueueRestrictions returns (true, reason) if the request should be
// denied due to task queue restrictions.
func (a *customAuthorizer) checkTaskQueueRestrictions(target *authorization.CallTarget) (bool, string) {
	if len(a.blockedTaskQueues) == 0 {
		return false, ""
	}

	tqName := extractTaskQueueName(target.Request)
	if tqName == "" {
		return false, ""
	}

	// Block worker polling on restricted task queues.
	if _, blocked := a.blockedTaskQueues[tqName]; blocked {
		if isWorkerPollingAPI(target.APIName) {
			return true, "task queue '" + tqName + "' is blocked from worker polling"
		}
	}

	return false, ""
}

// isWorkerPollingAPI returns true for APIs that workers call to pick up tasks.
func isWorkerPollingAPI(apiName string) bool {
	switch {
	case strings.HasSuffix(apiName, "/PollWorkflowTaskQueue"):
		return true
	case strings.HasSuffix(apiName, "/PollActivityTaskQueue"):
		return true
	}
	return false
}

// extractTaskQueueName extracts the task queue name from the request object.
// Handles the most common request types that carry a task queue.
func extractTaskQueueName(req any) string {
	if req == nil {
		return ""
	}
	type hasTaskQueue interface {
		GetTaskQueue() *taskqueuepb.TaskQueue
	}
	if r, ok := req.(hasTaskQueue); ok {
		if tq := r.GetTaskQueue(); tq != nil {
			return tq.GetName()
		}
	}
	// StartWorkflowExecution also has a task queue
	if r, ok := req.(*workflowservice.StartWorkflowExecutionRequest); ok {
		if tq := r.GetTaskQueue(); tq != nil {
			return tq.GetName()
		}
	}
	return ""
}

// taskQueueKind is used for task queue type assertions — normal vs sticky.
func isNormalTaskQueue(req any) bool {
	type hasTaskQueue interface {
		GetTaskQueue() *taskqueuepb.TaskQueue
	}
	if r, ok := req.(hasTaskQueue); ok {
		if tq := r.GetTaskQueue(); tq != nil {
			return tq.GetKind() == enumspb.TASK_QUEUE_KIND_NORMAL
		}
	}
	return true
}
