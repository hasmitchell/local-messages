package google

import (
	"context"
	"errors"
	"testing"
	"time"

	"go.mau.fi/mautrix-gmessages/pkg/libgm"
	"go.mau.fi/mautrix-gmessages/pkg/libgm/events"
	"go.mau.fi/mautrix-gmessages/pkg/libgm/gmproto"
)

type fakePhone struct {
	event        libgm.EventHandler
	check        func(context.Context) (*gmproto.IsBugleDefaultResponse, error)
	disconnected bool
}

func (p *fakePhone) Connect(context.Context) error              { return nil }
func (p *fakePhone) SetEventHandler(handler libgm.EventHandler) { p.event = handler }
func (p *fakePhone) Disconnect()                                { p.disconnected = true }
func (p *fakePhone) IsBugleDefault(ctx context.Context) (*gmproto.IsBugleDefaultResponse, error) {
	return p.check(ctx)
}

func TestConnectionReadyWithoutObsoleteClientReadyEvent(t *testing.T) {
	phone := &fakePhone{check: func(context.Context) (*gmproto.IsBugleDefaultResponse, error) {
		return &gmproto.IsBugleDefaultResponse{Success: true}, nil
	}}
	ctx, stop := context.WithTimeout(context.Background(), time.Second)
	defer stop()
	cancel, err := startPhoneConnection(ctx, phone)
	if err != nil {
		t.Fatal(err)
	}
	defer cancel()
	if phone.disconnected {
		t.Fatal("disconnected a responding phone")
	}
}

func TestReadinessCancellationAndFatalSessionCleanUp(t *testing.T) {
	for _, fatal := range []bool{false, true} {
		t.Run(map[bool]string{false: "cancelled", true: "fatal_session"}[fatal], func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			phone := &fakePhone{}
			phone.check = func(requestCtx context.Context) (*gmproto.IsBugleDefaultResponse, error) {
				if fatal {
					phone.event(&events.GaiaLoggedOut{})
				} else {
					cancel()
				}
				<-requestCtx.Done()
				return nil, requestCtx.Err()
			}
			_, err := startPhoneConnection(ctx, phone)
			if err == nil || !phone.disconnected {
				t.Fatal("failed connection was not cleaned up")
			}
			if !fatal && !errors.Is(err, context.Canceled) {
				t.Fatalf("lost cancellation: %v", err)
			}
		})
	}
}

func TestReadinessRejectsNonDefaultMessagesApp(t *testing.T) {
	phone := &fakePhone{check: func(context.Context) (*gmproto.IsBugleDefaultResponse, error) {
		return &gmproto.IsBugleDefaultResponse{Success: false}, nil
	}}
	_, err := startPhoneConnection(context.Background(), phone)
	if err == nil || !phone.disconnected {
		t.Fatal("accepted a phone without Google Messages as default")
	}
}
