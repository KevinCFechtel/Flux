use crate::domain::{CoreError, CoreEvent, MutationField};
use crate::miniflux::RemoteSource;
use crate::storage::Store;

/// Sends a durable snapshot. Conditional acknowledgement protects newer local intent.
pub(crate) fn deliver_pending(
    remote: &dyn RemoteSource,
    store: &Store,
    emit: &dyn Fn(CoreEvent),
) -> Result<u32, CoreError> {
    let pending = store.pending_mutations()?;
    tracing::info!(target: "mutation", "pending mutation delivery started pending={}", pending.len());
    let mut delivered = 0;
    for pending in pending {
        let result = match pending.field {
            MutationField::Read => remote.set_read_state(&[pending.article_id], pending.desired),
            MutationField::Starred => remote.set_starred_state(pending.article_id, pending.desired),
        };
        match result {
            Ok(()) => {
                store.acknowledge(&pending)?;
                delivered += 1;
                emit(CoreEvent::MutationDeliverySucceeded {
                    article_id: pending.article_id,
                    field: pending.field,
                });
            }
            Err(error) => {
                tracing::warn!(target: "mutation", "pending mutation delivery failed delivered={} kind={:?}", delivered, error.kind);
                emit(CoreEvent::MutationDeliveryFailed {
                    article_id: pending.article_id,
                    field: pending.field,
                    error_kind: error.kind.clone(),
                });
                return Err(error);
            }
        }
    }
    tracing::debug!(target: "mutation", "pending mutation delivery acknowledged delivered={delivered}");
    Ok(delivered)
}
