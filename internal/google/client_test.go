package google

import (
	"go.mau.fi/mautrix-gmessages/pkg/libgm/gmproto"
	"testing"
	"time"
)

func TestProtocolConversionPreservesPartsReactionsAndMicroseconds(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Microsecond)
	raw := &gmproto.Message{MessageID: "m", ConversationID: "c", Timestamp: now.UnixMicro(), Type: 4,
		MessageStatus: &gmproto.MessageStatus{Status: gmproto.MessageStatusType_OUTGOING_DELIVERED},
		MessageInfo: []*gmproto.MessageInfo{
			{Data: &gmproto.MessageInfo_MessageContent{MessageContent: &gmproto.MessageContent{Content: "Two photos"}}},
			{Data: &gmproto.MessageInfo_MediaContent{MediaContent: &gmproto.MediaContent{MediaID: "photo1", MediaName: "one.jpg", MimeType: "image/jpeg", DecryptionKey: []byte{1}}}},
			{Data: &gmproto.MessageInfo_MediaContent{MediaContent: &gmproto.MediaContent{MediaID: "photo2", MediaName: "two.jpg", MimeType: "image/jpeg", DecryptionKey: []byte{2}}}},
		},
		Reactions:    []*gmproto.ReactionEntry{{Data: &gmproto.ReactionData{Unicode: "❤️"}, ParticipantIDs: []string{"p"}}},
		ReplyMessage: &gmproto.ReplyMessage{MessageID: "parent"},
	}
	m := Convert(raw)
	if !m.Timestamp.Equal(now) || !m.Outgoing || m.Transport != "RCS" || m.Body != "Two photos" || m.ReplyTo != "parent" {
		t.Fatalf("conversion lost message fields: %+v", m)
	}
	if len(m.Attachments) != 2 || m.Attachments[0].ID == m.Attachments[1].ID || len(m.Reactions) != 1 {
		t.Fatalf("conversion lost multiple attachments/reactions: %+v", m)
	}
}

func TestOwnNumberCopiesDoNotNameConversation(t *testing.T) {
	person := func(id, name, number string, me bool) *gmproto.Participant {
		return &gmproto.Participant{ID: &gmproto.SmallInfo{ParticipantID: id, Number: number}, FullName: name, IsMe: me}
	}
	me, profile := person("2", "Me", "+61400000009", true), person("1828", "Me", "+61400000009", false)
	raw := &gmproto.Conversation{ConversationID: "c", Participants: []*gmproto.Participant{me, person("5", "Sam", "+61400000005", false), profile, profile}}
	if got := ConvertConversation(raw, "INBOX"); got.Name != "Sam" || len(got.Participants) != 4 {
		t.Fatalf("own-number copies named the conversation: %+v", got)
	}
	raw.Participants = []*gmproto.Participant{me, profile}
	if got := ConvertConversation(raw, "INBOX"); got.Name != "Me" {
		t.Fatalf("note to self lost its name: %+v", got)
	}
}

func TestThumbnailIsNotPresentedAsOriginal(t *testing.T) {
	raw := &gmproto.Message{MessageInfo: []*gmproto.MessageInfo{{Data: &gmproto.MessageInfo_MediaContent{MediaContent: &gmproto.MediaContent{ThumbnailMediaID: "thumb", ThumbnailDecryptionKey: []byte{1}, MimeType: "image/jpeg"}}}}}
	m := Convert(raw)
	if len(m.Attachments) != 1 || m.Attachments[0].State != "original_unavailable" || m.Attachments[0].MediaID != "" {
		t.Fatalf("thumbnail promoted to original: %+v", m)
	}
}

func TestDeletedMessageDoesNotKeepSearchableBody(t *testing.T) {
	raw := &gmproto.Message{MessageStatus: &gmproto.MessageStatus{Status: gmproto.MessageStatusType_MESSAGE_DELETED}, MessageInfo: []*gmproto.MessageInfo{{Data: &gmproto.MessageInfo_MessageContent{MessageContent: &gmproto.MessageContent{Content: "removed text"}}}}}
	m := Convert(raw)
	if m.Body != "" || len(m.Attachments) > 0 {
		t.Fatal("deleted content retained in projection")
	}
}
