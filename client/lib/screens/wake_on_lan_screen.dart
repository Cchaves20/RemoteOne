import 'package:flutter/material.dart';

/// Explica, em linguagem simples, como o "Ligar" (Wake-on-LAN) funciona, e
/// traz o modo avançado (roteador) com um aviso de segurança claro.
class WakeOnLanScreen extends StatelessWidget {
  const WakeOnLanScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Ligar o PC à distância')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Como funciona', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text(
            'Um computador desligado não consegue receber comandos sozinho. '
            'Mas, se você tem outro computador seu ligado na mesma casa (na '
            'mesma internet), o RemoteOne usa esse que está ligado para "acordar" '
            'o que está desligado.\n\n'
            'Resumindo: se você tem dois ou mais computadores na mesma rede e '
            'pelo menos um está ligado, o botão "Ligar" acende os outros — sem '
            'você precisar configurar nada.',
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: theme.colorScheme.primary),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Se todos os seus computadores dessa casa estiverem '
                      'desligados ao mesmo tempo, não dá para ligar nenhum à '
                      'distância. É preciso deixar pelo menos um ligado.',
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('Preparar o computador', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text(
            'Para um computador poder ser aceso à distância, esse recurso precisa '
            'estar ativado nele. Em geral:\n\n'
            '•  Ligue a opção "Wake on LAN" (ligar pela rede) nas configurações '
            'do computador. Ela costuma ficar numa tela de configurações que '
            'aparece logo quando o PC liga. Se não achar, pesquise na internet '
            '"ativar Wake on LAN" com o modelo do seu computador.\n\n'
            '•  Se puder, conecte o computador por cabo de rede — por Wi-Fi esse '
            'recurso costuma não funcionar.\n\n'
            '•  Desligue o computador normalmente, mas deixe-o na tomada.',
          ),
          const SizedBox(height: 16),
          const _RouterAdvanced(),
        ],
      ),
    );
  }
}

/// Modo avançado: ligar o PC de qualquer lugar (fora de casa). Recolhido por
/// padrão, com aviso de segurança em linguagem simples.
class _RouterAdvanced extends StatelessWidget {
  const _RouterAdvanced();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        leading: const Icon(Icons.router),
        title: const Text('Ligar de fora de casa (avançado)'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber, color: theme.colorScheme.onErrorContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Atenção: este modo "abre uma porta" no seu roteador para a '
                    'internet. Isso deixa a sua rede um pouco mais exposta a '
                    'riscos de segurança. Use só se tiver experiência. O modo '
                    'normal (acima) é seguro e não mexe em nada da sua rede.',
                    style: TextStyle(color: theme.colorScheme.onErrorContainer),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'O modo normal só funciona quando você e o computador ligado estão '
            'na mesma rede. Este modo avançado permite acender o PC mesmo estando '
            'longe de casa — mas depende do seu roteador e da sua operadora '
            '(algumas não permitem conexões de fora).',
          ),
          const SizedBox(height: 12),
          Text('Ideia geral', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          const Text(
            '•  Nas configurações do roteador, cria-se uma regra que deixa o '
            '"sinal para ligar" chegar da internet até o computador em casa.\n'
            '•  Alguns roteadores já têm um botão pronto chamado "Wake on LAN".\n'
            '•  Se você não tem familiaridade com configurações de roteador, o '
            'mais seguro é ficar no modo normal (deixar um computador ligado em '
            'casa).',
          ),
          const SizedBox(height: 12),
          const Text(
            'Este modo avançado ainda será integrado ao botão "Ligar" numa '
            'próxima atualização.',
            style: TextStyle(fontStyle: FontStyle.italic),
          ),
        ],
      ),
    );
  }
}
