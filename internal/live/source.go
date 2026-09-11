package live

import (
	"context"
	"go.mau.fi/mautrix-gmessages/pkg/libgm/gmproto"
	"local/GoogleMessagingAppMac/internal/archive"
	"local/GoogleMessagingAppMac/internal/history"
	"time"
)

type source interface {
	history.Source
	Conversations(context.Context, gmproto.ListConversationsRequest_Folder, int) ([]archive.Conversation, error)
	Lookup(context.Context, string) (archive.Conversation, bool, error)
	Download(context.Context, *archive.Store, time.Time, string, int64) error
	Save(context.Context) error
	Close()
}
type connector func(context.Context, string, func(any)) (source, error)
