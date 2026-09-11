package google

import (
	"github.com/google/uuid"
	"go.mau.fi/mautrix-gmessages/pkg/libgm/gmproto"
	"local/GoogleMessagingAppMac/internal/archive"
	"testing"
)

func TestTextRequestUsesCurrentConversationAndSIM(t *testing.T) {
	command := archive.SendCommand{Kind: "send_text", ID: uuid.NewString(), ConversationID: "c", Body: "Exact Unicode text 😀\nSecond line"}
	conv := &gmproto.Conversation{ConversationID: "c", DefaultOutgoingID: "self", Status: gmproto.ConversationStatus_ACTIVE}
	sim := &gmproto.SIMCard{SIMParticipant: &gmproto.SIMParticipant{ID: "self"}, SIMData: &gmproto.SIMData{SIMPayload: &gmproto.SIMPayload{SIMNumber: 2, Two: 1}}}
	req, err := buildTextRequest(command, conv, sim)
	if err != nil {
		t.Fatal(err)
	}
	if req.TmpID != command.ID || req.MessagePayload.TmpID != command.ID || req.MessagePayload.TmpID2 != command.ID || req.MessagePayload.ParticipantID != "self" || req.SIMPayload.SIMNumber != 2 || req.ForceRCS || req.MessagePayload.MessageInfo[0].GetMessageContent().GetContent() != command.Body {
		t.Fatal("incorrect send payload")
	}
	if _, err = buildTextRequest(command, conv, nil); err == nil {
		t.Fatal("guessed a missing SIM")
	}
	sim.SIMParticipant.ID = "other"
	if _, err = buildTextRequest(command, conv, sim); err == nil {
		t.Fatal("accepted wrong SIM")
	}
	sim.SIMParticipant.ID = "self"
	conv.ReadOnly = true
	if _, err = buildTextRequest(command, conv, sim); err == nil {
		t.Fatal("accepted read-only conversation")
	}
	conv.ReadOnly = false
	conv.ConversationID = "different"
	if _, err = buildTextRequest(command, conv, sim); err == nil {
		t.Fatal("changed recipient")
	}
}
