// poll-test.go — Test task queue blocking (Phase 10, Step 7).
//
// Tries to poll an activity task queue and prints whether it was blocked or allowed.
// Used to verify the custom authorizer's TEMPORAL_BLOCKED_TASK_QUEUES enforcement.
//
// Usage:
//   export TEMPORAL_TOKEN=$(go run scripts/dex-login.go)
//   go run scripts/poll-test.go HelloActivityTaskQueue   # expect: PermissionDenied
//   go run scripts/poll-test.go SomeOtherQueue           # expect: allowed (no task)

package main

import (
	"context"
	"fmt"
	"os"
	"time"

	"go.temporal.io/api/taskqueue/v1"
	"go.temporal.io/api/workflowservice/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
)

func main() {
	token := os.Getenv("TEMPORAL_TOKEN")
	if token == "" {
		fmt.Fprintln(os.Stderr, "TEMPORAL_TOKEN not set — run: export TEMPORAL_TOKEN=$(go run scripts/dex-login.go)")
		os.Exit(1)
	}

	tqName := "HelloActivityTaskQueue"
	if len(os.Args) > 1 {
		tqName = os.Args[1]
	}

	conn, err := grpc.NewClient("localhost:7233",
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	if err != nil {
		fmt.Fprintf(os.Stderr, "dial error: %v\n", err)
		os.Exit(1)
	}
	defer conn.Close()

	svc := workflowservice.NewWorkflowServiceClient(conn)

	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
	defer cancel()

	md := metadata.Pairs("authorization", "Bearer "+token)
	ctx = metadata.NewOutgoingContext(ctx, md)

	_, err = svc.PollActivityTaskQueue(ctx, &workflowservice.PollActivityTaskQueueRequest{
		Namespace: "default",
		TaskQueue: &taskqueue.TaskQueue{Name: tqName},
		Identity:  "test-worker",
	})
	if err != nil {
		fmt.Printf("Poll(%s): %v\n", tqName, err)
	} else {
		fmt.Printf("Poll(%s): ✅ allowed (no task — queue is NOT blocked)\n", tqName)
	}
}
