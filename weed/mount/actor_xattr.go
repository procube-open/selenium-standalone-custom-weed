package mount

import (
	"encoding/json"
	"os"
	"strings"
	"sync"

	"github.com/seaweedfs/seaweedfs/weed/pb/filer_pb"
)

type actorMetadata struct {
	Username    string `json:"username"`
	HistoryUUID string `json:"history_uuid"`
}

var (
	actorMetadataOnce   sync.Once
	cachedActorMetadata actorMetadata
)

func resolveActorMetadata() actorMetadata {
	actorMetadataOnce.Do(func() {
		username := strings.TrimSpace(os.Getenv("WEED_ACTOR_USERNAME"))
		historyUUID := strings.TrimSpace(os.Getenv("WEED_ACTOR_HISTORY_UUID"))
		if username != "" && historyUUID != "" {
			cachedActorMetadata = actorMetadata{Username: username, HistoryUUID: historyUUID}
			return
		}

		metadataFile := strings.TrimSpace(os.Getenv("WEED_ACTOR_METADATA_FILE"))
		if metadataFile == "" {
			return
		}
		payload, err := os.ReadFile(metadataFile)
		if err != nil {
			return
		}
		var parsed actorMetadata
		if err := json.Unmarshal(payload, &parsed); err != nil {
			return
		}
		parsed.Username = strings.TrimSpace(parsed.Username)
		parsed.HistoryUUID = strings.TrimSpace(parsed.HistoryUUID)
		if parsed.Username == "" || parsed.HistoryUUID == "" {
			return
		}
		cachedActorMetadata = parsed
	})
	return cachedActorMetadata
}

func injectActorXAttrs(entry *filer_pb.Entry) {
	if entry == nil {
		return
	}
	actor := resolveActorMetadata()
	if actor.Username == "" || actor.HistoryUUID == "" {
		return
	}
	if entry.Extended == nil {
		entry.Extended = make(map[string][]byte)
	}
	entry.Extended[XATTR_PREFIX+"user.admingate.username"] = []byte(actor.Username)
	entry.Extended[XATTR_PREFIX+"user.admingate.history_uuid"] = []byte(actor.HistoryUUID)
}
