use crate::domain::{CoreError, CoreEvent, MutationField};
use crate::miniflux::RemoteSource;
use crate::storage::Store;

/// Sends a durable snapshot. Conditional acknowledgement protects newer local intent.
pub(crate) fn deliver_pending(
    remote: &dyn RemoteSource,
    store: &Store,
    emit: &dyn Fn(CoreEvent),
) -> Result<(), CoreError> {
    for pending in store.pending_mutations()? {
        let result = match pending.field {
            MutationField::Read => remote.set_read_state(&[pending.article_id], pending.desired),
            MutationField::Starred => remote.set_starred_state(pending.article_id, pending.desired),
        };
        match result {
            Ok(()) => {
                store.acknowledge(&pending)?;
                emit(CoreEvent::MutationDeliverySucceeded {
                    article_id: pending.article_id,
                    field: pending.field,
                });
            }
            Err(error) => {
                emit(CoreEvent::MutationDeliveryFailed {
                    article_id: pending.article_id,
                    field: pending.field,
                    error_kind: error.kind.clone(),
                });
                return Err(error);
            }
        }
    }
    Ok(())
}
