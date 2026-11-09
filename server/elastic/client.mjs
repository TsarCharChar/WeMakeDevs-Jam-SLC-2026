export class ElasticError extends Error {
  constructor(status, type) {
    // Do not include response bodies: they can echo transcripts or credentials.
    super(`Elasticsearch HTTP ${status}: ${type}`);
    this.status = status;
    this.type = type;
  }
}

export function createClient(env = process.env, fetchImpl = fetch) {
  if (!env.ELASTICSEARCH_URL || !env.ELASTICSEARCH_API_KEY) {
    throw new Error('Set ELASTICSEARCH_URL and ELASTICSEARCH_API_KEY in the server environment or root .env.');
  }
  const url = new URL(env.ELASTICSEARCH_URL);
  if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash || url.pathname !== '/' || url.hostname.includes('.kb.')) {
    throw new Error('ELASTICSEARCH_URL must be the HTTPS Elasticsearch origin, not Kibana.');
  }
  return async function request(method, path, body) {
    const response = await fetchImpl(new URL(path, url), {
      method, redirect: 'error', signal: AbortSignal.timeout(120_000),
      headers: { Authorization: `ApiKey ${env.ELASTICSEARCH_API_KEY}`, 'Content-Type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const raw = await response.text();
    let data;
    try { data = raw ? JSON.parse(raw) : {}; } catch { data = {}; }
    if (!response.ok) throw new ElasticError(response.status, data.error?.type ?? 'request_failed');
    return data;
  };
}
