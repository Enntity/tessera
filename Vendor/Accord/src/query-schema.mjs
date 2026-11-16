// SPDX-License-Identifier: MIT
// Migration 17. Index the working set independently of retained history. Older
// migration checksums and the Messenger schema remain unchanged.
export const querySchema = `
CREATE INDEX claims_pending ON claims(created_at) WHERE state IN ('preparing','releasing','revoking');
CREATE INDEX claims_deadline ON claims(deadline) WHERE state IN ('preparing','running');
CREATE INDEX claims_open ON claims(resource) WHERE state!='closed';
CREATE INDEX claims_task ON claims(task_id);
CREATE INDEX tasks_queued ON tasks(created_at) WHERE state='queued';
CREATE INDEX sessions_expiring ON sessions(expires_at) WHERE closed_at IS NULL;
CREATE INDEX activity_session_seq ON session_activity(session_id,seq);
CREATE INDEX views_working ON session_views(id) WHERE hidden=0 AND state='working';
CREATE INDEX incidents_unresolved ON overseer_incidents(rule_id,session_id) WHERE state!='resolved';
CREATE INDEX incidents_open ON overseer_incidents(opened_at) WHERE state='open';
CREATE INDEX jobs_recent ON agent_jobs(updated_at DESC);
CREATE INDEX participants_recent ON participants(updated_at DESC);
CREATE INDEX views_progress ON session_views(progress_at DESC) WHERE hidden=0;
CREATE INDEX bindings_actor ON session_bindings(actor);
CREATE INDEX mail_retry ON message_outbox(last_attempt,created_at) WHERE state='queued';
CREATE INDEX mail_actor ON message_outbox(actor,created_at) WHERE state='queued';
CREATE INDEX manager_remote ON manager_requests(manager,remote_id);
CREATE INDEX manager_active ON manager_requests(last_checked,created_at) WHERE state NOT IN ('released','cancelled','failed');
`;
