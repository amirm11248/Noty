import { createClient } from 'npm:@supabase/supabase-js@2.117.2';
import {
  DeleteObjectCommand,
  DeleteObjectsCommand,
  GetObjectCommand,
  HeadObjectCommand,
  ListObjectsV2Command,
  ListObjectVersionsCommand,
  PutObjectCommand,
  S3Client,
} from 'npm:@aws-sdk/client-s3@3.922.0';
import { getSignedUrl } from 'npm:@aws-sdk/s3-request-presigner@3.922.0';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const jsonHeaders = { ...cors, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' };
const reply = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: jsonHeaders });

function safeRelativePath(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const path = value.trim();
  if (!path || path.length > 900 || path.startsWith('/') || path.includes('\\') || path.includes('\0')) return null;
  const parts = path.split('/');
  if (parts.some((part) => !part || part === '.' || part === '..')) return null;
  return parts.join('/');
}

function safeUUID(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const normalized = value.toLowerCase();
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(normalized)
    ? normalized
    : null;
}

function loadB2() {
  const keyId = Deno.env.get('B2_KEY_ID')?.trim();
  const applicationKey = Deno.env.get('B2_APPLICATION_KEY')?.trim();
  const bucket = Deno.env.get('B2_BUCKET_NAME')?.trim();
  let endpointRaw = Deno.env.get('B2_S3_ENDPOINT')?.trim();
  if (!keyId || !applicationKey || !bucket || !endpointRaw) return null;
  if (!/^https?:\/\//i.test(endpointRaw)) endpointRaw = 'https://' + endpointRaw;
  const endpoint = new URL(endpointRaw);
  const match = endpoint.hostname.match(/^s3\.([^.]+)\.backblazeb2\.com$/i);
  if (!match) return null;
  const client = new S3Client({
    region: match[1],
    endpoint: endpoint.origin,
    forcePathStyle: true,
    credentials: { accessKeyId: keyId, secretAccessKey: applicationKey },
  });
  return { client, bucket };
}

async function authenticatedUser(request: Request): Promise<{ id: string } | null> {
  const bearer = request.headers.get('Authorization')?.match(/^Bearer\s+(.+)$/i)?.[1];
  if (!bearer) return null;
  const url = Deno.env.get('SUPABASE_URL');
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
  if (!url || !anonKey) return null;
  const client = createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await client.auth.getUser(bearer);
  if (error || !data.user?.id) return null;
  return { id: data.user.id };
}

Deno.serve(async (request: Request) => {
  if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
  if (request.method !== 'POST') return reply(405, { message: 'Use POST.' });

  const user = await authenticatedUser(request);
  if (!user) return reply(401, { message: 'Sign in to use Noty Cloud.' });

  const b2 = loadB2();
  if (!b2) return reply(503, { message: 'Noty Cloud storage is not configured.' });

  if (Number(request.headers.get('content-length') ?? 0) > 32768) {
    return reply(413, { message: 'Request too large.' });
  }

  try {
    const body = await request.json();
    const action = typeof body?.action === 'string' ? body.action : '';
    const documentID = safeUUID(body?.documentID);

    if (action === 'presign_upload' || action === 'presign_download' || action === 'delete_object' || action === 'verify_upload') {
      const relativePath = safeRelativePath(body?.relativePath);
      if (!documentID || !relativePath) return reply(400, { message: 'Invalid document or asset path.' });

      const prefix = 'users/' + user.id + '/documents/' + documentID + '/';
      const hash = typeof body?.sha256 === 'string' && /^[0-9a-f]{64}$/.test(body.sha256) ? body.sha256 : null;
      const requestedKey = typeof body?.objectKey === 'string' ? body.objectKey : null;
      let objectKey = prefix + (hash ? 'versions/' + hash + '/' : '') + relativePath;
      if (requestedKey) {
        const suffix = requestedKey.startsWith(prefix) ? safeRelativePath(requestedKey.slice(prefix.length)) : null;
        if (!suffix || !(suffix === relativePath || /^versions\/[0-9a-f]{64}\//.test(suffix) && suffix.slice(74) === relativePath)) {
          return reply(400, { message: 'Invalid object version.' });
        }
        objectKey = requestedKey;
      }


      if (action === 'verify_upload') {
        const expected = body?.byteSize;
        if (!Number.isSafeInteger(expected) || expected < 0 || expected > 250 * 1024 * 1024) {
          return reply(400, { message: 'Invalid asset size.' });
        }
        const head = await b2.client.send(new HeadObjectCommand({ Bucket: b2.bucket, Key: objectKey }));
        if (head.ContentLength !== expected) return reply(409, { message: 'The upload is incomplete. Retry it.' });
        return reply(200, { ok: true, byteSize: head.ContentLength });
      }

      if (action === 'presign_upload') {
        if (requestedKey) return reply(400, { message: 'Use a content hash for uploads.' });
        const contentType =
          typeof body?.contentType === 'string' && body.contentType.length <= 200
            ? body.contentType
            : 'application/octet-stream';
        const command = new PutObjectCommand({
          Bucket: b2.bucket,
          Key: objectKey,
          ContentType: contentType,
        });
        const url = await getSignedUrl(b2.client, command, { expiresIn: 15 * 60 });
        return reply(200, { url, objectKey, expiresIn: 900 });
      }

      if (action === 'presign_download') {
        const command = new GetObjectCommand({ Bucket: b2.bucket, Key: objectKey });
        const url = await getSignedUrl(b2.client, command, { expiresIn: 15 * 60 });
        return reply(200, { url, objectKey, expiresIn: 900 });
      }

      await b2.client.send(new DeleteObjectCommand({ Bucket: b2.bucket, Key: objectKey }));
      return reply(200, { ok: true, objectKey });
    }

    if (action === 'delete_document') {
      if (!documentID) return reply(400, { message: 'Invalid document.' });
      const prefix = 'users/' + user.id + '/documents/' + documentID + '/';
  let deleted = 0;
  let keyMarker: string | undefined;
  let versionMarker: string | undefined;
  do {
    const listed = await b2.client.send(new ListObjectVersionsCommand({
      Bucket: b2.bucket, Prefix: prefix, KeyMarker: keyMarker,
      VersionIdMarker: versionMarker, MaxKeys: 1000,
    }));
    const objects = [...(listed.Versions ?? []), ...(listed.DeleteMarkers ?? [])]
      .flatMap(item => item.Key && item.VersionId ? [{Key:item.Key,VersionId:item.VersionId}] : []);
    if(objects.length) {
      const removed = await b2.client.send(new DeleteObjectsCommand({Bucket:b2.bucket,Delete:{Objects:objects,Quiet:true}}));
      if(removed.Errors?.length) throw new Error('Cloud deletion was incomplete.');
      deleted += objects.length;
    }
    keyMarker = listed.IsTruncated ? listed.NextKeyMarker : undefined;
    versionMarker = listed.IsTruncated ? listed.NextVersionIdMarker : undefined;
  } while(keyMarker);

      return reply(200, { ok: true, deleted });
    }

    return reply(400, { message: 'Unsupported Noty Cloud action.' });
  } catch (error) {
    console.error('noty-cloud-object failed', error instanceof Error ? error.message : String(error));
    return reply(502, { message: 'Noty Cloud storage request failed.' });
  }
});
