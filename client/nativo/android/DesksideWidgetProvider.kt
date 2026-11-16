// O widget do Deskside na tela inicial do Android.
//
// Este arquivo só desenha. Quem decide o que mostrar é o app, que grava tudo
// pronto pelo `home_widget` (ver `lib/services/widget_da_tela.dart`): o nome do
// computador, se está online e o texto de cada botão. O toque num botão roda o
// Dart do app em segundo plano, sem abri-lo.
//
// A linha `package` é trocada pela do MainActivity por
// `scripts/preparar-android.py`: o `home_widget` acha o widget pelo pacote do
// app mais o nome desta classe.
package com.deskside.deskside_client

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetBackgroundIntent
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

class DesksideWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        for (id in appWidgetIds) {
            appWidgetManager.updateAppWidget(id, desenhar(context, widgetData))
        }
    }

    private fun desenhar(context: Context, dados: SharedPreferences): RemoteViews {
        val vista = RemoteViews(context.packageName, R.layout.deskside_widget)
        val abrirApp = HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java)

        // Sem nada gravado (app nunca aberto desde a instalação do widget), ou
        // sem computador escolhido: um aviso, e o toque abre o app.
        val aviso = dados.getString("deskside_aviso", null)
        val nome = dados.getString("deskside_nome", null)
        if (aviso != null || nome == null) {
            vista.setTextViewText(
                R.id.deskside_nome,
                aviso ?: context.getString(R.string.deskside_widget_abra_o_app),
            )
            vista.setViewVisibility(R.id.deskside_bolinha, View.GONE)
            vista.setViewVisibility(R.id.deskside_botoes, View.GONE)
            vista.setOnClickPendingIntent(R.id.deskside_raiz, abrirApp)
            return vista
        }

        vista.setTextViewText(R.id.deskside_nome, nome)
        vista.setViewVisibility(R.id.deskside_bolinha, View.VISIBLE)
        vista.setImageViewResource(
            R.id.deskside_bolinha,
            if (dados.getBoolean("deskside_online", false)) {
                R.drawable.deskside_bolinha_online
            } else {
                R.drawable.deskside_bolinha_offline
            },
        )
        vista.setViewVisibility(R.id.deskside_botoes, View.VISIBLE)
        vista.setOnClickPendingIntent(R.id.deskside_raiz, abrirApp)

        val botoes = intArrayOf(R.id.deskside_botao_0, R.id.deskside_botao_1, R.id.deskside_botao_2)
        botoes.forEachIndexed { i, botao ->
            val texto = dados.getString("deskside_botao_${i}_texto", null)
            if (texto == null) {
                vista.setViewVisibility(botao, View.GONE)
            } else {
                vista.setViewVisibility(botao, View.VISIBLE)
                vista.setTextViewText(botao, texto)
                // Um endereço por botão: é o que faz o Android guardar três
                // pedidos distintos em vez de o último sobrescrever os outros.
                val toque = HomeWidgetBackgroundIntent.getBroadcast(
                    context,
                    Uri.parse("deskside://widget/botao?i=$i"),
                )
                vista.setOnClickPendingIntent(botao, toque)
            }
        }
        return vista
    }
}
