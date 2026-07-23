import 'package:flutter/material.dart';

/// Explica como o "Ligar" (Wake-on-LAN) funciona e traz o modo avançado
/// (roteador) com um aviso de segurança e o passo a passo.
class WakeOnLanScreen extends StatelessWidget {
  const WakeOnLanScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Ligar o PC (Wake-on-LAN)')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Como funciona', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text(
            'Um computador desligado não roda nada — só a placa de rede escuta '
            'um "sinal" na rede local. Como o servidor não alcança sua rede de '
            'casa, o RemoteOne usa outro computador seu que esteja ligado na '
            'mesma rede para enviar esse sinal.\n\n'
            'Ou seja: se você tem 2+ computadores na mesma rede e pelo menos um '
            'está ligado, o botão "Ligar" acorda os outros — sem configurar nada.',
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
                      'Se todos os computadores dessa rede estiverem desligados, '
                      'não há como acordá-los à distância — deixe ao menos um '
                      'ligado nessa rede.',
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text('No computador que você quer acordar', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text(
            '• Ative "Wake-on-LAN" na BIOS/UEFI e na placa de rede '
            '(propriedade "permitir que este dispositivo acorde o computador").\n'
            '• De preferência use cabo de rede (por Wi-Fi o WoL é instável).\n'
            '• Deixe o computador desligado ou suspenso, mas com energia.',
          ),
          const SizedBox(height: 16),
          const _RouterAdvanced(),
        ],
      ),
    );
  }
}

/// Modo avançado: acordar pela internet via roteador. Recolhido por padrão,
/// com aviso de segurança bem visível antes do passo a passo.
class _RouterAdvanced extends StatelessWidget {
  const _RouterAdvanced();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        leading: const Icon(Icons.router),
        title: const Text('Modo avançado: acordar pela internet (roteador)'),
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
                    'Aviso de segurança: este modo abre uma porta de entrada no '
                    'seu roteador para a internet, o que aumenta a superfície de '
                    'ataque da sua rede. Use apenas se souber o que está fazendo. '
                    'O modo padrão (acima) é mais seguro e não abre nada.',
                    style: TextStyle(color: theme.colorScheme.onErrorContainer),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Além disso, só funciona se sua operadora te dá IP público (sem '
            'CGNAT). Para testar: veja o IP WAN no painel do roteador e compare '
            'com o que aparece pesquisando "meu ip". Iguais = tem IP público; '
            'diferentes = CGNAT, e aí este modo não funciona.',
          ),
          const SizedBox(height: 12),
          Text('Passo a passo', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          const Text(
            '1. Reserve um IP fixo para o computador-alvo no roteador (DHCP).\n'
            '2. No roteador, crie um redirecionamento de porta (port forward) '
            'UDP da porta 9 para o endereço de broadcast da rede '
            '(ou um ARP estático apontando ao IP/MAC do alvo).\n'
            '3. Garanta que o WoL está ativado na BIOS e na placa de rede.\n'
            '4. Alguns roteadores (ex.: com OpenWrt/Merlin) têm um botão '
            '"Wake on LAN" próprio — se o seu tiver, use-o.',
          ),
          const SizedBox(height: 12),
          const Text(
            'Este modo ainda será integrado ao botão "Ligar" numa próxima '
            'atualização; por ora, o passo a passo serve para quem quer preparar '
            'o roteador.',
            style: TextStyle(fontStyle: FontStyle.italic),
          ),
        ],
      ),
    );
  }
}
