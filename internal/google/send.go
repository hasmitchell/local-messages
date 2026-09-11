package google

import (
	"context"
	"fmt"
	"time"

	"go.mau.fi/mautrix-gmessages/pkg/libgm/gmproto"
	"google.golang.org/protobuf/proto"
	"local/GoogleMessagingAppMac/internal/archive"
)

func (c *Client) receiveSettings(event any) {
	settings, ok := event.(*gmproto.Settings)
	if !ok {
		return
	}
	c.simMu.Lock()
	defer c.simMu.Unlock()
	c.sims = map[string]*gmproto.SIMCard{}
	for _, sim := range settings.GetSIMCards() {
		c.sims[sim.GetSIMParticipant().GetID()] = proto.Clone(sim).(*gmproto.SIMCard)
	}
}
func buildTextRequest(command archive.SendCommand, conv *gmproto.Conversation, sim *gmproto.SIMCard) (*gmproto.SendMessageRequest, error) {
	if !command.Valid() || conv.GetConversationID() != command.ConversationID || conv.GetReadOnly() {
		return nil, fmt.Errorf("conversation cannot send")
	}
	switch conv.GetStatus() {
	case gmproto.ConversationStatus_ACTIVE, gmproto.ConversationStatus_ARCHIVED, gmproto.ConversationStatus_KEEP_ARCHIVED:
	default:
		return nil, fmt.Errorf("conversation cannot send")
	}
	outgoing := conv.GetDefaultOutgoingID()
	if outgoing == "" || sim.GetSIMParticipant().GetID() != outgoing || sim.GetSIMData().GetSIMPayload() == nil {
		return nil, fmt.Errorf("phone SIM details unavailable")
	}
	request := &gmproto.SendMessageRequest{
		ConversationID: command.ConversationID, TmpID: command.ID,
		MessagePayload: &gmproto.MessagePayload{ConversationID: command.ConversationID, ParticipantID: outgoing, TmpID: command.ID, TmpID2: command.ID,
			MessageInfo: []*gmproto.MessageInfo{{Data: &gmproto.MessageInfo_MessageContent{MessageContent: &gmproto.MessageContent{Content: command.Body}}}}},
		SIMPayload: proto.Clone(sim.GetSIMData().GetSIMPayload()).(*gmproto.SIMPayload),
		// Follow the phone's transport settings; never force a fallback/retry.
		ForceRCS: false,
	}
	if command.ReplyTo != "" {
		request.Reply = &gmproto.ReplyPayload{MessageID: command.ReplyTo}
	}
	return request, nil
}

// Preflight performs only reads. The returned function makes exactly one send
// request, after the caller has durably recorded the 'sending' state.
func (c *Client) prepareRoute(ctx context.Context, command archive.SendCommand) (*gmproto.SendMessageRequest, error) {
	readCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	conv, err := c.GM.GetConversation(readCtx, command.ConversationID)
	if err != nil {
		return nil, &safeRequestError{label: "send preflight failed", cause: err}
	}
	c.simMu.Lock()
	sim := c.sims[conv.GetDefaultOutgoingID()]
	if sim != nil {
		sim = proto.Clone(sim).(*gmproto.SIMCard)
	}
	c.outgoing[conv.GetConversationID()] = conv.GetDefaultOutgoingID()
	c.simMu.Unlock()
	return buildTextRequest(command, conv, sim)
}

func (c *Client) PrepareText(ctx context.Context, command archive.SendCommand) (func(context.Context) (bool, error), error) {
	if command.Kind != "send_text" {
		return nil, fmt.Errorf("invalid message action")
	}
	req, err := c.prepareRoute(ctx, command)
	if err != nil {
		return nil, err
	}
	files, err := readStagedFiles(c.directory, command)
	if err != nil {
		return nil, err
	}
	return func(sendCtx context.Context) (bool, error) {
		if len(files) > 0 {
			req.MessagePayload.MessageInfo = nil
			for i, data := range files {
				if sendCtx.Err() != nil {
					return false, ErrNotSubmitted
				}
				media, err := c.GM.UploadMedia(data, command.Files[i].Name, command.Files[i].MIME)
				if err != nil {
					return false, ErrNotSubmitted
				}
				req.MessagePayload.MessageInfo = append(req.MessagePayload.MessageInfo, &gmproto.MessageInfo{Data: &gmproto.MessageInfo_MediaContent{MediaContent: media}})
			}
			if command.Body != "" {
				req.MessagePayload.MessageInfo = append(req.MessagePayload.MessageInfo, &gmproto.MessageInfo{Data: &gmproto.MessageInfo_MessageContent{MessageContent: &gmproto.MessageContent{Content: command.Body}}})
			}
		}
		if sendCtx.Err() != nil {
			return false, ErrNotSubmitted
		}
		resp, err := c.GM.SendMessage(sendCtx, req)
		if err != nil {
			return false, &safeRequestError{label: "send result unconfirmed", cause: err}
		}
		if resp == nil {
			return false, fmt.Errorf("send result unconfirmed")
		}
		switch resp.GetStatus() {
		case gmproto.SendMessageResponse_SUCCESS:
			return true, nil
		case 0, gmproto.SendMessageResponse_FAILURE_4:
			return false, nil
		default:
			return false, fmt.Errorf("send result unconfirmed")
		}
	}, nil
}
