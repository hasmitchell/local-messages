package google

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/google/uuid"
	"go.mau.fi/mautrix-gmessages/pkg/libgm/gmproto"
	"local/GoogleMessagingAppMac/internal/archive"
)

func TestStagedUploadCannotReadChangedOrExternalFiles(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, "drafts/attachments"), 0700)
	data := []byte("synthetic file")
	hash := sha256.Sum256(data)
	id := uuid.NewString()
	command := archive.SendCommand{Kind: "send_text", ID: uuid.NewString(), ConversationID: "c", Files: []archive.OutgoingFile{{ID: id, Name: "card.vcf", MIME: "text/vcard", Size: int64(len(data)), SHA256: hex.EncodeToString(hash[:])}}}
	path := filepath.Join(dir, "drafts/attachments", id)
	os.WriteFile(path, data, 0600)
	files, err := readStagedFiles(dir, command)
	if err != nil || len(files) != 1 || string(files[0]) != string(data) {
		t.Fatal("staged bytes changed", err)
	}
	os.WriteFile(path, []byte("changed"), 0600)
	if _, err := readStagedFiles(dir, command); err == nil {
		t.Fatal("uploaded a changed file")
	}
	os.Remove(path)
	outside := filepath.Join(t.TempDir(), "outside")
	os.WriteFile(outside, data, 0600)
	os.Symlink(outside, path)
	if _, err := readStagedFiles(dir, command); err == nil {
		t.Fatal("followed an outside symlink")
	}
	command.Files[0].ID = "../../outside"
	if command.Valid() {
		t.Fatal("accepted path traversal")
	}
}

func TestReactionUsesOnlyOwnReactionAndTargetConversation(t *testing.T) {
	command := archive.SendCommand{Kind: "react", ID: uuid.NewString(), ConversationID: "c", MessageID: "m", Emoji: "👍"}
	message := archive.Message{ID: "m", ConversationID: "c", Timestamp: time.Now(), Reactions: []archive.Reaction{{Emoji: "❤️", Participants: []string{"other"}}}}
	route := &gmproto.SendMessageRequest{MessagePayload: &gmproto.MessagePayload{ParticipantID: "self"}, SIMPayload: &gmproto.SIMPayload{SIMNumber: 2}}
	req, err := buildReactionRequest(command, message, route)
	if err != nil || req.Action != gmproto.SendReactionRequest_ADD || req.SIMPayload.SIMNumber != 2 {
		t.Fatal("wrong reaction routing", err)
	}
	command.Emoji = ""
	if _, err := buildReactionRequest(command, message, route); err == nil {
		t.Fatal("removed another participant's reaction")
	}
	message.Reactions = append(message.Reactions, archive.Reaction{Emoji: "😂", Participants: []string{"self"}})
	req, err = buildReactionRequest(command, message, route)
	if err != nil || req.Action != gmproto.SendReactionRequest_REMOVE || req.ReactionData.GetUnicode() != "😂" {
		t.Fatal("wrong remove reaction", err)
	}
	command.Emoji = "😮"
	req, err = buildReactionRequest(command, message, route)
	if err != nil || req.Action != gmproto.SendReactionRequest_SWITCH {
		t.Fatal("did not replace own reaction")
	}
	message.ConversationID = "different"
	if _, err := buildReactionRequest(command, message, route); err == nil {
		t.Fatal("cross-conversation reaction")
	}
}
