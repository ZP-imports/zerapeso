-- 20_cobranca_avulsa.sql
-- Cobrança sem pedido: a equipe escolhe um cliente (cadastrado ou importado), informa o valor
-- e a cobrança entra em Pagamentos como qualquer outra (pendente, ou Carteira se for pré-datada).
-- Não cria tabela nem coluna nova: grava uma linha em public.pedidos já entregue, marcada com
-- extra.cobranca = true, para reaproveitar tudo o que já existe (enviar link, parcelas, marcar pago).
-- Rode este arquivo uma vez no SQL Editor da Supabase.

create or replace function public.criar_cobranca(
  p_nome text,
  p_fone text,
  p_cidade text,
  p_descricao text,
  p_valor numeric
) returns bigint
language plpgsql security definer set search_path = public as $$
declare
  novo bigint;
  desc_txt text;
  quem text;
begin
  if not public.eh_gestao() then raise exception 'Sem permissão para criar cobranças.'; end if;
  if coalesce(btrim(p_nome), '') = '' then raise exception 'Informe o cliente.'; end if;
  if p_valor is null or p_valor <= 0 then raise exception 'Informe o valor da cobrança.'; end if;

  desc_txt := coalesce(nullif(btrim(p_descricao), ''), 'Cobrança');
  select coalesce(nome, 'Equipe') into quem from public.perfis where id = auth.uid();

  insert into public.pedidos (usuario_id, seq, status, itens, entrega, pagamento, extra)
  values (
    auth.uid(), 1, 'entregue',
    jsonb_build_array(jsonb_build_object('id', 0, 'name', desc_txt, 'qty', 1, 'unit', round(p_valor, 2), 'unidades', 1)),
    jsonb_build_object(
      'nome', btrim(p_nome),
      'fone', regexp_replace(coalesce(p_fone, ''), '\D', '', 'g'),
      'dest', jsonb_build_object('cidade', coalesce(btrim(p_cidade), ''))
    ),
    '{"modo":"link","status":"pendente","taxaEntrega":0}'::jsonb,
    jsonb_build_object('cobranca', true)
  )
  returning id into novo;

  insert into public.pedido_eventos (pedido_id, tipo, publico, texto, por)
  values (novo, 'pagamento', false, 'Cobrança criada sem pedido: ' || desc_txt || ' (R$ ' || to_char(round(p_valor, 2), 'FM999G999G990D00') || ')', coalesce(quem, 'Equipe'));

  return novo;
end $$;

revoke all on function public.criar_cobranca(text, text, text, text, numeric) from public, anon;
grant execute on function public.criar_cobranca(text, text, text, text, numeric) to authenticated;
