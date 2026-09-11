package google

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"go.mau.fi/mautrix-gmessages/pkg/libgm"
	"go.mau.fi/mautrix-gmessages/pkg/libgm/gmproto"
	"local/GoogleMessagingAppMac/internal/archive"
)

func TestFullSizeDownloadReferenceArrivesAsMessageEvent(t *testing.T) {
	key := mediaReference{"message", "image-part"}
	client := &Client{mediaWaiters: map[mediaReference]*mediaWaiter{key: {updates: make(chan archive.Attachment, 1)}}}
	action := "image-part"
	update := &libgm.WrappedMessage{Message: &gmproto.Message{MessageID: "message", MessageInfo: []*gmproto.MessageInfo{{ActionMessageID: &action, Data: &gmproto.MessageInfo_MediaContent{MediaContent: &gmproto.MediaContent{MediaID: "original", DecryptionKey: []byte{1}, MimeType: "image/jpeg", Size: 123}}}}}}
	client.receiveMediaUpdate(update)
	select {
	case a := <-client.mediaWaiters[key].updates:
		if a.MediaID != "original" || a.Size != 123 || len(a.Key) != 1 {
			t.Fatal("original metadata was lost")
		}
	default:
		t.Fatal("did not route original update to requesting attachment")
	}
}

func TestOriginalUpdateCanPrecedeEmptyAcknowledgement(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	updates := make(chan archive.Attachment, 1)
	a, err := awaitOriginal(ctx, updates, func(requestCtx context.Context) error {
		updates <- archive.Attachment{MediaID: "original"}
		<-requestCtx.Done()
		return requestCtx.Err()
	})
	if err != nil || a.MediaID != "original" {
		t.Fatalf("lost early update: %+v %v", a, err)
	}
}

func TestAcknowledgementAloneDoesNotCountAsDownloadedOriginal(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Millisecond)
	defer cancel()
	_, err := awaitOriginal(ctx, make(chan archive.Attachment), func(context.Context) error { return nil })
	if err == nil {
		t.Fatal("empty acknowledgement counted as original availability")
	}
	var failure *originalRequestError
	if !errors.As(err, &failure) || failure.stage != "update after acknowledgement" || !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("lost failure stage or cancellation: %v", err)
	}
}

func TestLateAndSiblingUpdatesRemainAvailable(t *testing.T) {
	client := &Client{}
	first, second := "first", "second"
	client.receiveMediaUpdate(&libgm.WrappedMessage{Message: &gmproto.Message{MessageID: "message", MessageInfo: []*gmproto.MessageInfo{
		{ActionMessageID: &first, Data: &gmproto.MessageInfo_MediaContent{MediaContent: &gmproto.MediaContent{MediaID: "original-1", DecryptionKey: []byte{1}}}},
		{ActionMessageID: &second, Data: &gmproto.MessageInfo_MediaContent{MediaContent: &gmproto.MediaContent{MediaID: "original-2", DecryptionKey: []byte{2}}}},
	}}})
	for i, action := range []string{first, second} {
		a := archive.Attachment{ID: action, State: "original_request_failed"}
		// No configured phone client: a successful lookup must use the event
		// retained before either attachment had an active waiter.
		if err := client.resolveOriginal(context.Background(), "message", &a); err != nil {
			t.Fatal(err)
		}
		if a.MediaID != fmt.Sprintf("original-%d", i+1) || a.State != "pending" {
			t.Fatalf("lost late or sibling update: %+v", a)
		}
	}
}

func TestOriginalCacheIsBounded(t *testing.T) {
	client := &Client{}
	action := "part"
	for i := 0; i <= maxCachedMediaReferences; i++ {
		client.receiveMediaUpdate(&libgm.WrappedMessage{Message: &gmproto.Message{MessageID: fmt.Sprint(i), MessageInfo: []*gmproto.MessageInfo{
			{ActionMessageID: &action, Data: &gmproto.MessageInfo_MediaContent{MediaContent: &gmproto.MediaContent{MediaID: "original", DecryptionKey: []byte{1}}}},
		}}})
	}
	if len(client.mediaCache) != maxCachedMediaReferences || len(client.mediaCacheOrder) != maxCachedMediaReferences {
		t.Fatal("media cache grew beyond its bound")
	}
	if _, exists := client.mediaCache[mediaReference{"0", action}]; exists {
		t.Fatal("oldest reference was not evicted")
	}
}
