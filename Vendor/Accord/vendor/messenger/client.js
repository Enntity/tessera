import fs from "node:fs";

export class MessengerClient {
  constructor({ url = "http://127.0.0.1:7780", token = null, tokenFile = null } = {}) {
    this.url = validateBaseUrl(url);
    this.token = token || (tokenFile ? readTokenFile(tokenFile) : null);
    if (!this.token) throw new Error("A Messenger token or token file is required");
  }

  request(path, { method = "GET", body = null, signal = null } = {}) {
    return fetch(`${this.url}${path}`, {
      method,
      headers: {
        authorization: `Bearer ${this.token}`,
        ...(body == null ? {} : { "content-type": "application/json" })
      },
      ...(body == null ? {} : { body: JSON.stringify(body) }),
      redirect: "error",
      signal
    }).then(async (response) => {
      const payload = await response.json().catch(() => ({}));
      if (!response.ok) {
        const error = new Error(payload?.error?.message || `Messenger request failed: ${response.status}`);
        error.code = payload?.error?.code || "REQUEST_FAILED";
        error.status = response.status;
        throw error;
      }
      return payload;
    });
  }

  requestBytes(path, { method = "GET", body = null, headers = {}, signal = null } = {}) {
    return fetch(`${this.url}${path}`, {
      method,
      headers: { authorization: `Bearer ${this.token}`, ...headers },
      ...(body == null ? {} : { body }),
      redirect: "error",
      signal
    }).then(async (response) => {
      if (!response.ok) {
        const payload = await response.json().catch(() => ({}));
        const error = new Error(payload?.error?.message || `Messenger request failed: ${response.status}`);
        error.code = payload?.error?.code || "REQUEST_FAILED";
        error.status = response.status;
        throw error;
      }
      return {
        bytes: Buffer.from(await response.arrayBuffer()),
        mimeType: response.headers.get("content-type") || "application/octet-stream",
        sha256: response.headers.get("x-content-sha256") || null
      };
    });
  }

  me() { return this.request("/v1/me"); }
  principals() { return this.request("/v1/principals"); }
  createPrincipal(input) { return this.request("/v1/principals", { method: "POST", body: input }); }
  createInvite(input = {}) { return this.request("/v1/invites", { method: "POST", body: input }); }
  credentials(handle) {
    return this.request(`/v1/principals/${encodeURIComponent(handle)}/credentials`);
  }
  issueCredential(handle) {
    return this.request(`/v1/principals/${encodeURIComponent(handle)}/credentials`, { method: "POST" });
  }
  revokeCredential(credentialId) {
    return this.request(`/v1/credentials/${encodeURIComponent(credentialId)}`, { method: "DELETE" });
  }
  conversations() { return this.request("/v1/conversations"); }
  createConversation(input) { return this.request("/v1/conversations", { method: "POST", body: input }); }
  conversation(conversationId) {
    return this.request(`/v1/conversations/${encodeURIComponent(conversationId)}`);
  }
  messages(conversationId, { after = 0, limit = 100 } = {}) {
    return this.request(`/v1/conversations/${encodeURIComponent(conversationId)}/messages?after=${after}&limit=${limit}`);
  }
  send(conversationId, input) {
    return this.request(`/v1/conversations/${encodeURIComponent(conversationId)}/messages`, { method: "POST", body: input });
  }
  message(messageId) { return this.request(`/v1/messages/${encodeURIComponent(messageId)}`); }
  messageByClientId(clientMessageId) {
    return this.request(`/v1/messages/by-client/${encodeURIComponent(clientMessageId)}`);
  }
  upload(bytes, { name = "attachment", mimeType = "application/octet-stream", metadata = null } = {}) {
    return this.requestBytes("/v1/blobs", {
      method: "POST",
      body: Buffer.isBuffer(bytes) ? bytes : Buffer.from(bytes || ""),
      headers: {
        "content-type": mimeType,
        "x-enntity-filename": name,
        ...(metadata == null ? {} : { "x-enntity-metadata": JSON.stringify(metadata) })
      }
    }).then(({ bytes: response }) => JSON.parse(response.toString("utf8")));
  }
  download(blobId) { return this.requestBytes(`/v1/blobs/${encodeURIComponent(blobId)}`); }
  inbox({ waitMs = 0, limit = 20, claim = true, deliveryId = null, messageId = null, conversationId = null, signal = null } = {}) {
    const query = new URLSearchParams({ waitMs: String(waitMs), limit: String(limit), claim: String(claim) });
    if (deliveryId) query.set("deliveryId", deliveryId);
    if (messageId) query.set("messageId", messageId);
    if (conversationId) query.set("conversationId", conversationId);
    return this.request(`/v1/inbox?${query}`, { signal });
  }
  read(deliveryId, leaseToken) {
    return this.request(`/v1/deliveries/${encodeURIComponent(deliveryId)}/read`, { method: "POST", body: { leaseToken } });
  }
  ack(deliveryId, leaseToken) {
    return this.request(`/v1/deliveries/${encodeURIComponent(deliveryId)}/ack`, { method: "POST", body: { leaseToken } });
  }
  retry(deliveryId, input = {}) {
    return this.request(`/v1/deliveries/${encodeURIComponent(deliveryId)}/retry`, { method: "POST", body: input });
  }
  receipts(messageId) { return this.request(`/v1/messages/${encodeURIComponent(messageId)}/receipts`); }
  drafts({ limit = 50 } = {}) { return this.request(`/v1/drafts?limit=${limit}`); }
  createDraft(input) { return this.request("/v1/drafts", { method: "POST", body: input }); }
  draft(draftId) { return this.request(`/v1/drafts/${encodeURIComponent(draftId)}`); }
  sendDraft(draftId) { return this.request(`/v1/drafts/${encodeURIComponent(draftId)}/send`, { method: "POST" }); }
  discardDraft(draftId) { return this.request(`/v1/drafts/${encodeURIComponent(draftId)}`, { method: "DELETE" }); }
}

function validateBaseUrl(value) {
  const url = new URL(String(value || "http://127.0.0.1:7780"));
  const loopback = ["127.0.0.1", "[::1]", "::1", "localhost"].includes(url.hostname);
  if (url.username || url.password) throw new Error("Messenger URL must not contain credentials");
  if (url.protocol !== "https:" && !(url.protocol === "http:" && loopback)) {
    throw new Error("Messenger URL must use HTTPS, except for loopback HTTP");
  }
  if (url.search || url.hash) throw new Error("Messenger URL must not contain a query or fragment");
  url.pathname = url.pathname.replace(/\/$/, "");
  return url.toString().replace(/\/$/, "");
}

function readTokenFile(file) {
  const resolved = String(file || "");
  const stat = fs.lstatSync(resolved);
  if (!stat.isFile()) throw new Error("Messenger token file must be a regular file, not a symlink");
  if (process.platform !== "win32" && (stat.mode & 0o077)) {
    throw new Error("Messenger token file must not be readable or writable by group or other users");
  }
  return fs.readFileSync(resolved, "utf8").trim();
}
