-- =====================================================================
-- ZP Imports | Correção: a proteção do perfil bloqueava funções do sistema
-- A proteção agora vale só para mudanças vindas do navegador do cliente.
-- Como usar: SQL Editor > nova consulta > cole TUDO > Run.
-- =====================================================================
create or replace function public.proteger_perfil() returns trigger
language plpgsql security invoker set search_path = public as $$
begin
  if current_user in ('authenticated', 'anon') and not public.eh_admin() then
    if new.id <> old.id
       or new.papel is distinct from old.papel
       or new.ativo is distinct from old.ativo
       or new.email is distinct from old.email
       or new.codigo_indicacao is distinct from old.codigo_indicacao
       or new.indicado_por is distinct from old.indicado_por then
      raise exception 'Você não pode alterar esses campos do perfil.';
    end if;
  end if;
  return new;
end $$;
