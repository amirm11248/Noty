-- Keep the shared document CAS contract reproducible on a fresh backend.
create or replace function public.noty_web_stamp()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at = now();
  new.revision = old.revision + 1;
  return new;
end;
$$;
drop trigger if exists noty_web_document_stamp on public.noty_web_documents;
create trigger noty_web_document_stamp before update on public.noty_web_documents
for each row execute function public.noty_web_stamp();
