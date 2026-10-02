import { createClient } from 'npm:@supabase/supabase-js@2.117.2';
import { makeDeleteAccountHandler } from './handler.ts';

Deno.serve(makeDeleteAccountHandler({ createClient, env: (key: string) => Deno.env.get(key) }));
