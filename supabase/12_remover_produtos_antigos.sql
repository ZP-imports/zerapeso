-- =====================================================================
-- ZP Imports | Remove os produtos antigos (acessórios e exemplos)
-- Mantém só os produtos com foto (ids 101 a 107). As variações dos removidos
-- saem junto. Pedidos já feitos não são afetados (guardam o próprio texto).
-- Como usar: SQL Editor > nova consulta > cole TUDO > Run.
-- =====================================================================

delete from public.produtos where id not between 101 and 107;

-- conferência: deve listar só os 7 produtos
select id, sku, nome, categoria from public.produtos order by id;
