type Identity = { id: string; email?: string | null };
type AccountClient = {
  auth: {
    getUser(jwt: string): Promise<{ data: { user: Identity | null }; error: unknown }>;
    signInWithPassword(credentials: { email: string; password: string }): Promise<{ data: { user: Identity | null; session: { access_token: string } | null }; error: unknown }>;
    admin: {
      signOut(jwt: string, scope: 'global'): Promise<{ error: unknown }>;
      deleteUser(id: string): Promise<{ error: unknown }>;
    };
  };
};
type Dependencies = {
  env: (key: string) => string | undefined;
  createClient: (url: string, key: string, options: { auth: { persistSession: boolean; autoRefreshToken: boolean } }) => AccountClient;
  deleteCloudData?: (userID: string) => Promise<void>;
};
const cors = {'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization, apikey, content-type, x-client-info','Access-Control-Allow-Methods':'POST, OPTIONS'};
const headers = { ...cors, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' };
const reply = (status: number, message: string) => new Response(JSON.stringify({ message }), { status, headers });

export function makeDeleteAccountHandler(deps: Dependencies) {
  return async (request: Request): Promise<Response> => {
    if (request.method === 'OPTIONS') return new Response(null,{status:204,headers:cors});
    if (request.method !== 'POST') return reply(405, 'Use POST.');
    const bearer = request.headers.get('Authorization')?.match(/^Bearer\s+(.+)$/i)?.[1];
    if (!bearer) return reply(401, 'Sign in to delete your account.');
    if (Number(request.headers.get('content-length') ?? 0) > 4096) return reply(413, 'Request too large.');
    try {
      const url = deps.env('SUPABASE_URL');
      const serviceKey = deps.env('SUPABASE_SERVICE_ROLE_KEY');
      const publicKey = deps.env('SUPABASE_ANON_KEY');
      if (!url || !serviceKey || !publicKey) return reply(503, 'Account deletion is temporarily unavailable.');
      const options = { auth: { persistSession: false, autoRefreshToken: false } };
      const admin = deps.createClient(url, serviceKey, options);
      const { data: identity, error: identityError } = await admin.auth.getUser(bearer);
      if (identityError || !identity.user?.email) return reply(401, 'Sign in again to delete your account.');
      const body = await request.json();
      if (body.confirmation !== 'DELETE' || typeof body.password !== 'string' || body.password.length < 1 || body.password.length > 1024) return reply(400, 'Enter your password and confirm deletion.');
      const verifier = deps.createClient(url, publicKey, options);
      const { data: verified, error: passwordError } = await verifier.auth.signInWithPassword({ email: identity.user.email, password: body.password });
      if (passwordError || !verified.session || verified.user?.id !== identity.user.id) return reply(403, 'The password could not be verified.');
      try {
        await deps.deleteCloudData?.(identity.user.id);
      } catch {
        return reply(503, 'Your cloud files could not be deleted. Your account is still active; please retry.');
      }
      const { error: signOutError } = await admin.auth.admin.signOut(verified.session.access_token, 'global');
      if (signOutError) return reply(503, 'Please try again. Your account has not been deleted.');
      const { error: deleteError } = await admin.auth.admin.deleteUser(identity.user.id);
      if (deleteError) return reply(503, 'Your account could not be deleted. Sign in again and retry.');
      return reply(200, 'Account deleted.');
    } catch { return reply(400, 'The request could not be completed. Please try again.'); }
  };
}
