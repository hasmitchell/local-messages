package google

import (
	"context"
	"errors"
	"fmt"

	"time"

	"go.mau.fi/mautrix-gmessages/pkg/libgm"
	"go.mau.fi/mautrix-gmessages/pkg/libgm/events"
	"go.mau.fi/mautrix-gmessages/pkg/libgm/gmproto"
)

type listRequest func(context.Context, int, gmproto.ListConversationsRequest_Folder) (*gmproto.ListConversationsResponse, error)

// The first upstream list request uses BUGLE_ANNOTATION; it can time out while
// a later ordinary request succeeds. Retry a timed-out read once in the same
// session. Do not keep retrying account errors or a cancelled parent context.
func listConversations(ctx context.Context, request listRequest, count int, folder gmproto.ListConversationsRequest_Folder) (*gmproto.ListConversationsResponse, error) {
	var err error
	for attempt := 0; attempt < 2; attempt++ {
		requestCtx, cancel := context.WithTimeout(ctx, 45*time.Second)
		var response *gmproto.ListConversationsResponse
		response, err = request(requestCtx, count, folder)
		cancel()
		if err == nil {
			return response, nil
		}
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		if !errors.Is(err, context.DeadlineExceeded) && !errors.Is(err, libgm.ErrPhoneNotResponding) {
			return nil, err
		}
	}
	return nil, err
}

// Error strings from a remote service can include user data. Expose only error
// categories and numeric status codes, never response bodies, cookies or keys.
func diagnostic(err error) string {
	var originalErr *originalRequestError
	if errors.As(err, &originalErr) {
		return originalErr.Error()
	}
	switch {
	case errors.Is(err, context.DeadlineExceeded):
		return "request timed out"
	case errors.Is(err, context.Canceled):
		return "request cancelled"
	case errors.Is(err, libgm.ErrPhoneNotResponding):
		return "phone response timed out"
	case errors.Is(err, libgm.ErrConnectionClosed):
		return "connection closed"
	}
	var requestErr events.RequestError
	if errors.As(err, &requestErr) {
		return fmt.Sprintf("Google error code %d", requestErr.Data.GetType())
	}
	var httpErr events.HTTPError
	if errors.As(err, &httpErr) && httpErr.Resp != nil {
		return fmt.Sprintf("HTTP %d", httpErr.Resp.StatusCode)
	}
	return fmt.Sprintf("protocol error %T", err)
}

// Preserve machine-readable causes without exposing the remote error string.
type safeRequestError struct {
	label string
	cause error
}

func (e *safeRequestError) Error() string { return e.label + " (" + diagnostic(e.cause) + ")" }
func (e *safeRequestError) Unwrap() error { return e.cause }
