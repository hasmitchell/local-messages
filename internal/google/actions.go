package google

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"go.mau.fi/mautrix-gmessages/pkg/libgm/gmproto"
	"local/GoogleMessagingAppMac/internal/archive"
)

var ErrNotSubmitted = errors.New("attachment preparation failed before message submission")

func readStagedFiles(directory string, command archive.SendCommand) ([][]byte, error) {
	if len(command.Files) == 0 {
		return nil, nil
	}
	if !command.Valid() {
		return nil, ErrNotSubmitted
	}
	// OpenRoot confines reads to the local staging folder, including symlinks.
	archiveRoot, err := filepath.EvalSymlinks(directory)
	if err != nil {
		return nil, ErrNotSubmitted
	}
	staging := filepath.Join(archiveRoot, "drafts", "attachments")
	resolved, err := filepath.EvalSymlinks(staging)
	if err != nil || resolved != staging {
		return nil, ErrNotSubmitted
	}
	root, err := os.OpenRoot(staging)
	if err != nil {
		return nil, ErrNotSubmitted
	}
	defer root.Close()
	var files [][]byte
	for _, info := range command.Files {
		file, err := root.Open(info.ID)
		if err != nil {
			return nil, ErrNotSubmitted
		}
		stat, statErr := file.Stat()
		if statErr != nil || !stat.Mode().IsRegular() || stat.Size() != info.Size {
			file.Close()
			return nil, ErrNotSubmitted
		}
		data, err := io.ReadAll(io.LimitReader(file, archive.MaxUploadBytes+1))
		file.Close()
		hash := sha256.Sum256(data)
		if err != nil || int64(len(data)) != info.Size || hex.EncodeToString(hash[:]) != info.SHA256 {
			return nil, ErrNotSubmitted
		}
		files = append(files, data)
	}
	return files, nil
}

func buildReactionRequest(command archive.SendCommand, target archive.Message, route *gmproto.SendMessageRequest) (*gmproto.SendReactionRequest, error) {
	if !command.Valid() || command.Kind != "react" || target.ID != command.MessageID || target.ConversationID != command.ConversationID || strings.Contains(target.Status, "DELETED") || route.GetMessagePayload().GetParticipantID() == "" {
		return nil, fmt.Errorf("reaction target unavailable")
	}
	own := ""
	for _, reaction := range target.Reactions {
		for _, id := range reaction.Participants {
			if id == route.GetMessagePayload().GetParticipantID() {
				own = reaction.Emoji
			}
		}
	}
	action := gmproto.SendReactionRequest_ADD
	emoji := command.Emoji
	if own != "" {
		action = gmproto.SendReactionRequest_SWITCH
	}
	if emoji == "" {
		if own == "" {
			return nil, fmt.Errorf("no saved reaction to remove")
		}
		action = gmproto.SendReactionRequest_REMOVE
		emoji = own
	}
	return &gmproto.SendReactionRequest{MessageID: target.ID, ReactionData: gmproto.MakeReactionData(emoji), Action: action, SIMPayload: route.SIMPayload}, nil
}

func (c *Client) PrepareReaction(ctx context.Context, command archive.SendCommand, target archive.Message) (func(context.Context) (bool, error), error) {
	route, err := c.prepareRoute(ctx, command)
	if err != nil {
		return nil, err
	}
	request, err := buildReactionRequest(command, target, route)
	if err != nil {
		return nil, err
	}
	return func(ctx context.Context) (bool, error) {
		response, err := c.GM.SendReaction(ctx, request)
		if err != nil || response == nil {
			return false, fmt.Errorf("reaction result unconfirmed")
		}
		return response.GetSuccess(), nil
	}, nil
}
