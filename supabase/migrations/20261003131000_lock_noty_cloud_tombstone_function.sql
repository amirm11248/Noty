-- The trigger is internal; clients should not be able to invoke the SECURITY DEFINER function through RPC.
revoke all on function public.noty_record_cloud_tombstone() from public;
revoke all on function public.noty_record_cloud_tombstone() from anon;
revoke all on function public.noty_record_cloud_tombstone() from authenticated;
