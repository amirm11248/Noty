import { createClient } from 'npm:@supabase/supabase-js@2.117.2';
import {
  DeleteObjectsCommand,
  ListObjectsV2Command,
  S3Client,
} from 'npm:@aws-sdk/client-s3@3.922.0';
import { makeDeleteAccountHandler } from './handler.ts';

function b2Client() {
  const keyId = Deno.env.get('B2_KEY_ID')?.trim();
  const applicationKey = Deno.env.get('B2_APPLICATION_KEY')?.trim();
  const bucket = Deno.env.get('B2_BUCKET_NAME')?.trim();
  let endpointRaw = Deno.env.get('B2_S3_ENDPOINT')?.trim();
  if (!keyId || !applicationKey || !bucket || !endpointRaw) {
    throw new Error('Noty Cloud storage is not configured.');
  }
  if (!/^https?:\/\//i.test(endpointRaw)) endpointRaw = 'https://' + endpointRaw;
  const endpoint = new URL(endpointRaw);
  const match = endpoint.hostname.match(/^s3\.([^.]+)\.backblazeb2\.com$/i);
  if (!match) throw new Error('Invalid Backblaze endpoint.');

  return {
    bucket,
    client: new S3Client({
      region: match[1],
      endpoint: endpoint.origin,
      forcePathStyle: true,
      credentials: { accessKeyId: keyId, secretAccessKey: applicationKey },
    }),
  };
}

async function deleteCloudData(userID: string) {
  const { bucket, client } = b2Client();
  const prefix = `users/${userID}/`;
  let continuationToken: string | undefined;

  do {
    const listed = await client.send(new ListObjectsV2Command({
      Bucket: bucket,
      Prefix: prefix,
      ContinuationToken: continuationToken,
      MaxKeys: 1000,
    }));
    const objects = (listed.Contents ?? []).flatMap((item) => item.Key ? [{ Key: item.Key }] : []);
    if (objects.length) {
      await client.send(new DeleteObjectsCommand({
        Bucket: bucket,
        Delete: { Objects: objects, Quiet: true },
      }));
    }
    continuationToken = listed.IsTruncated ? listed.NextContinuationToken : undefined;
  } while (continuationToken);
}

Deno.serve(makeDeleteAccountHandler({
  createClient,
  env: (key: string) => Deno.env.get(key),
  deleteCloudData,
}));
