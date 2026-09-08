"""As regras de assinatura de loja, e o que cada uma impede de acontecer.

Cada teste aqui existe por causa de um jeito conhecido de ganhar plano pago sem
pagar, ou de continuar pago depois de ter recebido o dinheiro de volta. O nome
de cada um diz qual.

Regra pura: nada de servidor, nada de banco, nada de rede — o que permite
exercitar a renovação do mês que vem sem esperar um mês.
"""

from datetime import UTC, datetime, timedelta

import pytest

from app.assinatura import (
    Ambiente,
    Compra,
    Estado,
    Loja,
    ate_quando,
    deve_aplicar,
    produto_pago,
    vale_como_pago,
)

AGORA = datetime(2026, 9, 8, 12, 0, tzinfo=UTC)
PRODUTO = "com.deskside.pro.mensal"


def compra(
    estado: Estado = Estado.ATIVA,
    ambiente: Ambiente = Ambiente.PRODUCAO,
    product_id: str = PRODUTO,
    dias: int | None = 30,
    visto_em: datetime = AGORA,
) -> Compra:
    return Compra(
        loja=Loja.APPLE,
        id_original="1000000000000001",
        product_id=product_id,
        estado=estado,
        ambiente=ambiente,
        expira_em=None if dias is None else AGORA + timedelta(days=dias),
        visto_em=visto_em,
    )


class TestValeComoPago:
    def test_assinatura_ativa_e_dentro_do_prazo_vale(self):
        assert vale_como_pago(compra(), agora=AGORA) is True

    def test_sandbox_nao_vale_em_producao(self):
        """O buraco que dá plano pago de graça para quem tem um Mac.

        O ambiente de teste das lojas emite comprovantes **legítimos**,
        assinados com as chaves de verdade, comprados com cartões que não
        existem. Um servidor que não separe os dois ambientes não tem plano
        pago: tem plano opcional para quem sabe abrir o Xcode.
        """
        de_teste = compra(ambiente=Ambiente.SANDBOX)
        assert vale_como_pago(de_teste, agora=AGORA) is False
        # E vale quando alguém liga a chave de propósito, para o teste ponta a
        # ponta antes de a loja publicar.
        assert vale_como_pago(de_teste, agora=AGORA, aceitar_sandbox=True) is True

    def test_produto_desconhecido_nao_vale(self):
        """O aplicativo roda no aparelho de outra pessoa e afirma o que quiser.

        Se um dia existir um produto de R$ 2 e a conferência for por "comprou
        alguma coisa", ele libera o plano de R$ 30.
        """
        assert vale_como_pago(compra(product_id="com.deskside.adesivo"), agora=AGORA) is False

    def test_reembolso_vence_a_data_de_validade(self):
        """O caso que custa dinheiro de verdade.

        A pessoa assina, usa o mês, pede estorno pela loja — e a validade ainda
        não chegou. Sem esta regra ela fica paga até o fim do prazo que já foi
        devolvido, e o padrão é repetível todo mês.
        """
        estornada = compra(estado=Estado.REVOGADA, dias=30)
        assert estornada.expira_em > AGORA  # a data ainda está no futuro
        assert vale_como_pago(estornada, agora=AGORA) is False

    def test_cancelada_continua_valendo_ate_o_fim_do_mes_pago(self):
        """Cancelar não é perder na hora — o mês foi pago.

        Cortar aqui é o caminho mais curto para um pedido de reembolso e uma
        avaliação de uma estrela.
        """
        assert vale_como_pago(compra(estado=Estado.CANCELADA), agora=AGORA) is True

    def test_em_atraso_continua_valendo_durante_a_graca(self):
        """Cartão recusado não é calote.

        A loja tenta de novo por alguns dias e mantém o acesso; cortar no
        primeiro erro perde o cliente exatamente no momento em que ele mais
        precisaria que o produto funcionasse.
        """
        assert vale_como_pago(compra(estado=Estado.EM_ATRASO), agora=AGORA) is True

    def test_prazo_vencido_nao_vale(self):
        assert vale_como_pago(compra(dias=-1), agora=AGORA) is False

    def test_expirada_sem_data_nao_vale(self):
        assert vale_como_pago(compra(estado=Estado.EXPIRADA, dias=None), agora=AGORA) is False

    def test_produto_pago_confere_a_lista(self):
        assert produto_pago(PRODUTO) is True
        assert produto_pago("qualquer.outra.coisa") is False


class TestDeveAplicar:
    """Notificação repetida e fora de ordem — o normal, não a exceção.

    As lojas reenviam até receber confirmação, e não prometem ordem.
    """

    def test_a_primeira_sempre_entra(self):
        assert deve_aplicar(None, compra()) is True

    def test_notificacao_repetida_e_ignorada(self):
        """Sem isto, uma renovação reenviada estenderia a validade duas vezes."""
        assert deve_aplicar(AGORA, compra(visto_em=AGORA)) is False

    def test_notificacao_atrasada_nao_desfaz_a_mais_nova(self):
        """O pior caso: um `renovou` antigo chegando depois de um `reembolsou`.

        Sem a comparação de carimbos, ele religa o acesso de quem já recebeu o
        dinheiro de volta — e ninguém percebe, porque tudo parece ter dado certo.
        """
        antiga = compra(estado=Estado.ATIVA, visto_em=AGORA - timedelta(hours=1))
        assert deve_aplicar(AGORA, antiga) is False

    def test_notificacao_mais_nova_entra(self):
        nova = compra(estado=Estado.REVOGADA, visto_em=AGORA + timedelta(minutes=1))
        assert deve_aplicar(AGORA, nova) is True

    def test_assinar_de_novo_depois_de_cancelar_volta_a_valer(self):
        """A regra não pode ser "revogada nunca mais liga".

        Seria simples e estaria errada: quem cancelou e voltou é um cliente
        voltando, e a loja reusa o mesmo identificador de transação. Comparar
        carimbos resolve os dois casos com a mesma linha.
        """
        depois = AGORA + timedelta(days=40)
        renovada = compra(estado=Estado.ATIVA, visto_em=depois)
        assert deve_aplicar(AGORA, renovada) is True


class TestAteQuando:
    def test_devolve_a_validade_quando_a_compra_vale(self):
        c = compra()
        assert ate_quando(c) == c.expira_em

    @pytest.mark.parametrize(
        "invalida",
        [
            compra(estado=Estado.REVOGADA),
            compra(ambiente=Ambiente.SANDBOX),
            compra(product_id="com.deskside.outro"),
            compra(dias=-1),
        ],
        ids=["reembolsada", "sandbox", "produto-errado", "vencida"],
    )
    def test_devolve_none_para_rebaixar(self, invalida):
        """`None` é a ordem de rebaixar, e é o retorno que não pode ser esquecido.

        Quem chama grava `plano_ate` com o que sair daqui; um retorno otimista
        deixaria contas pagas para sempre.
        """
        assert ate_quando(invalida) is None
