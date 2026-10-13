-- =====================================================================
-- ZP Imports | Fotos dos produtos
-- Cria a pasta pública "produtos" no Storage do Supabase e a coluna "imagem"
-- (nome do arquivo da foto). Por padrão, a foto de cada produto novo é "SKU.jpg",
-- por exemplo 5831.jpg para o produto de SKU 5831.
-- Rode depois do 01 ao 05. Pode rodar mais de uma vez.
-- Como usar: SQL Editor > nova consulta > cole TUDO > Run.
-- =====================================================================

alter table public.produtos add column if not exists imagem text;

update public.produtos set imagem = sku || '.jpg' where id between 101 and 107 and imagem is null;

-- pasta pública para LER as fotos (qualquer visitante vê), só administrador grava
insert into storage.buckets (id, name, public)
values ('produtos', 'produtos', true)
on conflict (id) do update set public = true;

update storage.buckets
   set file_size_limit = 5242880,
       allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp']
 where id = 'produtos';

drop policy if exists produtos_fotos_ler on storage.objects;
create policy produtos_fotos_ler on storage.objects for select to anon, authenticated
  using (bucket_id = 'produtos');

drop policy if exists produtos_fotos_gravar on storage.objects;
create policy produtos_fotos_gravar on storage.objects for insert to authenticated
  with check (bucket_id = 'produtos' and public.eh_admin());

drop policy if exists produtos_fotos_trocar on storage.objects;
create policy produtos_fotos_trocar on storage.objects for update to authenticated
  using (bucket_id = 'produtos' and public.eh_admin())
  with check (bucket_id = 'produtos' and public.eh_admin());

drop policy if exists produtos_fotos_apagar on storage.objects;
create policy produtos_fotos_apagar on storage.objects for delete to authenticated
  using (bucket_id = 'produtos' and public.eh_admin());
