package google

import (
	"context"
	"errors"
	"strings"
	"testing"

	"go.mau.fi/mautrix-gmessages/pkg/libgm/events"
	"go.mau.fi/mautrix-gmessages/pkg/libgm/gmproto"
)

func TestConversationListingRecoversAfterInitialTimeout(t *testing.T) {
	calls := 0
	request := func(ctx context.Context, count int, folder gmproto.ListConversationsRequest_Folder) (*gmproto.ListConversationsResponse, error) {
		calls++
		if calls == 1 {
			return nil, context.DeadlineExceeded
		}
		return &gmproto.ListConversationsResponse{Conversations: []*gmproto.Conversation{{ConversationID: "c"}}}, nil
	}
	response, err := listConversations(context.Background(), request, 1000, gmproto.ListConversationsRequest_INBOX)
	if err != nil || calls != 2 || len(response.GetConversations()) != 1 {
		t.Fatalf("retry failed: calls=%d error=%v", calls, err)
	}
}

func TestConversationListingRetryIsBounded(t *testing.T) {
	for _, test := range []struct {
		name  string
		err   error
		calls int
	}{{"timeout", context.DeadlineExceeded, 2}, {"account", errors.New("sensitive account response"), 1}} {
		t.Run(test.name, func(t *testing.T) {
			calls := 0
			request := func(context.Context, int, gmproto.ListConversationsRequest_Folder) (*gmproto.ListConversationsResponse, error) {
				calls++
				return nil, test.err
			}
			_, err := listConversations(context.Background(), request, 1000, gmproto.ListConversationsRequest_INBOX)
			if err == nil || calls != test.calls {
				t.Fatalf("calls=%d error=%v", calls, err)
			}
		})
	}
}

func TestDiagnosticDoesNotExposeRemoteErrorText(t *testing.T) {
	for _, err := range []error{errors.New("private-token-123"), events.RequestError{Data: &gmproto.ErrorResponse{Type: 16, Message: "private-token-123"}}} {
		if strings.Contains(diagnostic(err), "private-token-123") {
			t.Fatal("exposed remote error payload")
		}
	}
}
