use std::collections::HashMap;

use crate::MediaProgressCapability;
use crate::domain::{CoreError, CoreEvent, MutationField};
use crate::miniflux::RemoteSource;
use crate::storage::Store;

#[derive(Clone, Debug, Default)]
pub(crate) struct DeliveryResult {
    pub count: u32,
    pub media_progress: HashMap<i64, u64>,
}

/// Sends article and enclosure mutations using their typed durable stores.
pub(crate) fn deliver_pending(
    remote: &dyn RemoteSource,
    store: &Store,
    media_progress_capability: MediaProgressCapability,
    emit: &dyn Fn(CoreEvent),
) -> Result<DeliveryResult, CoreError> {
    let mut result = DeliveryResult::default();
    for pending in store.pending_mutations()? {
        match pending.field {
            MutationField::Read => remote.set_read_state(&[pending.article_id], pending.desired),
            MutationField::Starred => remote.set_starred_state(pending.article_id, pending.desired),
        }?;
        store.acknowledge(&pending)?;
        result.count += 1;
        emit(CoreEvent::MutationDeliverySucceeded {
            article_id: pending.article_id,
            field: pending.field,
        });
    }
    for pending in store.pending_media_progress_mutations()? {
        match media_progress_capability {
            MediaProgressCapability::Unsupported => {
                // The local checkpoint remains authoritative; only its unsupported remote intent is obsolete.
                store.discard_media_progress(&pending)?;
            }
            MediaProgressCapability::Unknown => {}
            MediaProgressCapability::Supported => {
                match remote
                    .set_media_progression(pending.enclosure_id, pending.progression_seconds)
                {
                    Ok(()) => {
                        store.acknowledge_media_progress(&pending)?;
                        result.count += 1;
                        result
                            .media_progress
                            .insert(pending.enclosure_id, pending.progression_seconds);
                    }
                    Err(error) if matches!(error.http_status(), Some(404 | 410)) => {
                        // A gone enclosure cannot accept progress, but it must not remove local playback.
                        store.discard_media_progress(&pending)?;
                    }
                    Err(error) => return Err(error),
                }
            }
        }
    }
    Ok(result)
}
