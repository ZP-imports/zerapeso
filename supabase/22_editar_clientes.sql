-- 22_editar_clientes.sql
-- Libera editar e excluir clientes importados na aba Clientes do painel:
--   1) coluna CEP na lista de clientes importados;
--   2) permissão para a equipe de gestão editar e excluir esses cadastros.
-- Só mexe em public.clientes_importados. Pedidos, cobranças e cadastros do site não são afetados.
-- Rode este arquivo uma vez no SQL Editor da Supabase.

alter table public.clientes_importados add column if not exists cep text;

drop policy if exists clientes_importados_editar_gestao on public.clientes_importados;
create policy clientes_importados_editar_gestao on public.clientes_importados
  for update to authenticated
  using (public.eh_gestao()) with check (public.eh_gestao());

drop policy if exists clientes_importados_excluir_gestao on public.clientes_importados;
create policy clientes_importados_excluir_gestao on public.clientes_importados
  for delete to authenticated
  using (public.eh_gestao());
