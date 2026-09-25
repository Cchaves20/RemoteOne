import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Mantém o app acima da barra de navegação do Android.
///
/// ## O defeito
///
/// No Android o app desenha **por baixo** das barras do sistema ("ponta a
/// ponta"): o Android 15 obriga isso a quem mira nele, e a tela de controle
/// reativa o modo ao sair (`SystemUiMode.edgeToEdge`). Quem precisa ceder
/// espaço à barra é o app.
///
/// O Flutter faz isso sozinho numa `ListView` — mas **só quando ela não
/// recebe `padding`**. Um `padding: EdgeInsets.all(16)`, que é o que quase
/// toda tela deste app tem, substitui o recuo automático. O efeito: o último
/// item de cada lista fica embaixo dos botões de voltar/início/recentes. O
/// botão "Entendi" da tela de gestos ficou literalmente coberto por eles, e o
/// fim das Configurações não chega nunca à área visível.
///
/// Eram 8 das 17 telas com esse padrão. Corrigir uma a uma deixaria a
/// próxima tela nascer com o mesmo defeito; aqui o recuo é dado **uma vez**,
/// em volta do app inteiro.
///
/// ## O que fica de fora, e por quê
///
/// - **O topo.** A `AppBar` já cuida da barra de status, e pintar por trás
///   dela é o que faz a cor da barra de título subir até a borda da tela.
/// - **O iOS.** Lá a faixa de baixo é o indicador de início, fino e
///   translúcido, e as telas já foram usadas e aprovadas como estão. Mesmo
///   critério da tela de controle, que também trata só o Android.
/// - **A tela de controle**, na prática: ela esconde as barras
///   (`immersiveSticky`), o recuo pedido pelo sistema vai a zero, e o vídeo
///   continua ocupando a tela inteira.
///
/// A faixa atrás da barra recebe a cor de fundo do tema, para não aparecer
/// um vão de outra cor quando os botões do sistema são translúcidos.
///
/// Usado como `MaterialApp.builder`, que fica **acima** do `Navigator`: vale
/// para toda rota, diálogo e folha de baixo que o app abrir.
Widget respeitarBarraDoSistema(BuildContext context, Widget? child) {
  final conteudo = child ?? const SizedBox.shrink();
  if (defaultTargetPlatform != TargetPlatform.android) return conteudo;
  return ColoredBox(
    color: Theme.of(context).scaffoldBackgroundColor,
    child: SafeArea(top: false, child: conteudo),
  );
}
