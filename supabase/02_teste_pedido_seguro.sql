-- =====================================================================
-- ZP Imports | Teste automático da Fase 2 (não grava nada)
-- Como usar: SQL Editor > New query > cole TUDO > Run.
-- O resultado aparece como uma mensagem de ERRO começando com "RELATORIO".
-- Isso é proposital: o erro desfaz tudo, e o texto do erro é o relatório.
-- =====================================================================
do $$
declare
  a uuid := gen_random_uuid();
  b uuid := gen_random_uuid();
  rel text := '';
  r jsonb;
  d date := public.hoje_br() + 2;
  dia date;
  prod_antes int;
  prod_depois int;
  n int;
  cod_a text;
  cod_b text;
begin
  -- próxima data que não seja domingo
  dia := d;
  while extract(dow from dia) = 0 loop dia := dia + 1; end loop;

  -- dois clientes de teste (como administrador do banco)
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_user_meta_data, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', a, 'authenticated', 'authenticated', 'teste-a@exemplo.invalid', '', now(),
          '{"nome":"Ana","sobrenome":"Teste","fone":"(12) 9 8111-2222"}'::jsonb, now(), now()),
         ('00000000-0000-0000-0000-000000000000', b, 'authenticated', 'authenticated', 'teste-b@exemplo.invalid', '', now(),
          '{"nome":"Beto","sobrenome":"Teste","fone":"(12) 9 8333-4444"}'::jsonb, now(), now());
  update public.perfis set endereco = '{"cep":"12327-000","uf":"SP","cidade":"Jacareí","bairro":"Centro","rua":"Rua A","num":"10","comp":"","ref":""}'::jsonb where id = a;
  update public.perfis set endereco = '{"cep":"12245-000","uf":"SP","cidade":"São José dos Campos","bairro":"Urbanova","rua":"Rua B","num":"20","comp":"","ref":""}'::jsonb where id = b;
  rel := rel || E'Perfis criados automaticamente: ' || (select count(*) from public.perfis where id in (a, b)) || E' (esperado 2)\n';
  rel := rel || E'Papel do cliente novo: ' || (select string_agg(distinct papel, ',') from public.perfis where id in (a, b)) || E' (esperado cliente)\n';
  select estoque into prod_antes from public.produtos where id = 1;
  select codigo_indicacao into cod_a from public.perfis where id = a;
  select codigo_indicacao into cod_b from public.perfis where id = b;

  -- a partir daqui, agimos como cliente logado (sem poderes de administrador)
  set local role authenticated;

  -- 1) cliente A compra o produto 1 tentando mandar um preço falso
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', a::text, true);
  r := public.criar_pedido(
    jsonb_build_array(jsonb_build_object('id', 1, 'qty', 1, 'opt', 'Caixa com 1 caneta', 'unit', 1, 'preco', 1)),
    jsonb_build_object('data', dia::text, 'turno', 'manha', 'obs', 'teste'), null, false);
  rel := rel || E'1) Pedido com preço falso enviado: total=' || (r->>'total') || ' desconto=' || (r->>'desconto') || ' tipo=' || coalesce(r->>'tipo_desconto', '-') || E'  (esperado total 809.10, tipo primeira)\n';
  rel := rel || E'   Código do pedido: ' || (r->>'codigo') || E'\n';

  -- estoque foi reservado
  reset role;
  select estoque into prod_depois from public.produtos where id = 1;
  rel := rel || E'2) Estoque do produto 1: antes=' || prod_antes || ' depois=' || prod_depois || E'  (esperado depois = antes - 1)\n';
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', a::text, true);

  -- 3) turno inválido
  begin
    perform public.criar_pedido(jsonb_build_array(jsonb_build_object('id', 3, 'qty', 1)),
      jsonb_build_object('data', dia::text, 'turno', 'madrugada'), null, false);
    rel := rel || E'3) Turno inválido: ERRO, deveria ter sido recusado\n';
  exception when others then
    rel := rel || E'3) Turno inválido recusado: ' || sqlerrm || E'\n';
  end;

  -- 4) estoque insuficiente
  begin
    perform public.criar_pedido(jsonb_build_array(jsonb_build_object('id', 3, 'qty', 99)),
      jsonb_build_object('data', dia::text, 'turno', 'tarde'), null, false);
    rel := rel || E'4) Estoque insuficiente: ERRO, deveria ter sido recusado\n';
  exception when others then
    rel := rel || E'4) Estoque insuficiente recusado: ' || sqlerrm || E'\n';
  end;

  -- 5) data antes do prazo
  begin
    perform public.criar_pedido(jsonb_build_array(jsonb_build_object('id', 3, 'qty', 1)),
      jsonb_build_object('data', public.hoje_br()::text, 'turno', 'tarde'), null, false);
    rel := rel || E'5) Data de hoje: ERRO, deveria ter sido recusada\n';
  exception when others then
    rel := rel || E'5) Data de hoje recusada: ' || sqlerrm || E'\n';
  end;

  -- 6) inserir pedido direto, sem a função
  begin
    insert into public.pedidos (usuario_id, itens, entrega) values (a, '[]'::jsonb, '{}'::jsonb);
    rel := rel || E'6) Inserção direta: ERRO, deveria ter sido negada\n';
  exception when others then
    rel := rel || E'6) Inserção direta negada: ' || sqlerrm || E'\n';
  end;

  -- 7) mudar o próprio papel
  begin
    update public.perfis set papel = 'admin' where id = a;
    get diagnostics n = row_count;
    rel := rel || E'7) Mudar o próprio papel: linhas alteradas=' || n || E' (erro de bloqueio ou 0 é o esperado)\n';
  exception when others then
    rel := rel || E'7) Mudar o próprio papel negado: ' || sqlerrm || E'\n';
  end;
  rel := rel || E'   Papel de A continua: ' || (select papel from public.perfis where id = a) || E'\n';

  -- 8) cliente B: indicação com o código de A
  perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', b::text, true);
  r := public.validar_indicacao(cod_a);
  rel := rel || E'8) Código de A validado por B: ' || r::text || E'\n';
  r := public.criar_pedido(jsonb_build_array(jsonb_build_object('id', 4, 'qty', 1)),
    jsonb_build_object('data', dia::text, 'turno', 'tarde'), cod_a, false);
  rel := rel || E'   Pedido de B com indicação: total=' || (r->>'total') || ' tipo=' || coalesce(r->>'tipo_desconto', '-') || E'  (esperado 377.10, indicacao)\n';

  -- 9) B tenta usar o próprio código
  r := public.validar_indicacao(cod_b);
  rel := rel || E'9) B usando o próprio código: ' || (r->>'erro') || E'\n';

  -- 10) B não enxerga os pedidos de A, e A não enxerga os de B
  select count(*) into n from public.pedidos where usuario_id = a;
  rel := rel || E'10) B enxerga pedidos de A: ' || n || E' (esperado 0)\n';
  select count(*) into n from public.pedidos where usuario_id = b;
  rel := rel || E'    B enxerga os próprios pedidos: ' || n || E' (esperado 1)\n';

  -- 11) sem login, ninguém cria pedido
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  begin
    perform public.criar_pedido(jsonb_build_array(jsonb_build_object('id', 3, 'qty', 1)),
      jsonb_build_object('data', dia::text, 'turno', 'tarde'), null, false);
    rel := rel || E'11) Sem login: ERRO, deveria ter sido recusado\n';
  exception when others then
    rel := rel || E'11) Sem login recusado: ' || sqlerrm || E'\n';
  end;

  reset role;
  raise exception E'RELATORIO (nada foi gravado):\n%', rel;
end $$;
