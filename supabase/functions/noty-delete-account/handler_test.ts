import { makeDeleteAccountHandler } from './handler.ts';

function fixture(options: { invalidIdentity?: boolean; wrongPassword?: boolean; differentUser?: boolean; signOutError?: boolean; deleteError?: boolean } = {}) {
  const events: string[] = [];
  const client = { auth: {
    getUser: async (_jwt: string) => ({ data: { user: options.invalidIdentity ? null : { id: 'caller-id', email: 'student@example.invalid' } }, error: options.invalidIdentity ? 'invalid' : null }),
    signInWithPassword: async (_credentials: { email: string; password: string }) => ({ data: { user: { id: options.differentUser ? 'other-id' : 'caller-id' }, session: { access_token: 'fresh-token' } }, error: options.wrongPassword ? 'wrong' : null }),
    admin: {
      signOut: async (_jwt: string, _scope: 'global') => { events.push('sign-out'); return { error: options.signOutError ? 'failed' : null }; },
      deleteUser: async (id: string) => { events.push(`delete:${id}`); return { error: options.deleteError ? 'failed' : null }; },
    },
  } };
  const handler = makeDeleteAccountHandler({ env: () => 'configured', createClient: () => client });
  const request = (body: unknown = { password: 'test-password', confirmation: 'DELETE', user_id: 'victim-id' }, authorized = true) => new Request('https://example.invalid', { method: 'POST', headers: { ...(authorized ? { Authorization: 'Bearer test-token' } : {}), 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  return { handler, request, events };
}
function equal(actual: unknown, expected: unknown) { if (JSON.stringify(actual) !== JSON.stringify(expected)) throw new Error(`Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`); }
Deno.test('rejects unauthenticated calls without touching accounts', async () => { const f = fixture(); equal((await f.handler(f.request({}, false))).status, 401); equal(f.events, []); });
Deno.test('rejects invalid identity', async () => { const f = fixture({ invalidIdentity: true }); equal((await f.handler(f.request())).status, 401); equal(f.events, []); });
Deno.test('requires explicit deletion confirmation', async () => { const f = fixture(); equal((await f.handler(f.request({ password: 'test-password' }))).status, 400); equal(f.events, []); });
Deno.test('rejects wrong password', async () => { const f = fixture({ wrongPassword: true }); equal((await f.handler(f.request())).status, 403); equal(f.events, []); });
Deno.test('rejects password session for another identity', async () => { const f = fixture({ differentUser: true }); equal((await f.handler(f.request())).status, 403); equal(f.events, []); });
Deno.test('revokes sessions then deletes only caller, ignoring supplied user id', async () => { const f = fixture(); equal((await f.handler(f.request())).status, 200); equal(f.events, ['sign-out', 'delete:caller-id']); });
Deno.test('does not delete account when session revocation fails', async () => { const f = fixture({ signOutError: true }); equal((await f.handler(f.request())).status, 503); equal(f.events, ['sign-out']); });
Deno.test('reports deletion failure honestly', async () => { const f = fixture({ deleteError: true }); equal((await f.handler(f.request())).status, 503); equal(f.events, ['sign-out', 'delete:caller-id']); });
