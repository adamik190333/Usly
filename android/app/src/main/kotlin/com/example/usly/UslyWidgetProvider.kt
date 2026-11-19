package com.example.usly

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

class UslyWidgetProvider : HomeWidgetProvider() {

    private fun loadWidgetBitmap(path: String): Bitmap? {
        try {
            val bounds = BitmapFactory.Options().apply {
                inJustDecodeBounds = true
            }

            BitmapFactory.decodeFile(path, bounds)

            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
                return null
            }

            val maxSize = 600
            var sampleSize = 1

            while (
                bounds.outWidth / sampleSize > maxSize ||
                bounds.outHeight / sampleSize > maxSize
            ) {
                sampleSize *= 2
            }

            val options = BitmapFactory.Options().apply {
                inSampleSize = sampleSize
                inPreferredConfig = Bitmap.Config.RGB_565
            }

            val bitmap = BitmapFactory.decodeFile(path, options)
                ?: return null

            val scale = minOf(
                1f,
                maxSize.toFloat() / maxOf(bitmap.width, bitmap.height)
            )

            if (scale < 1f) {
                val resized = Bitmap.createScaledBitmap(
                    bitmap,
                    (bitmap.width * scale).toInt().coerceAtLeast(1),
                    (bitmap.height * scale).toInt().coerceAtLeast(1),
                    true
                )

                if (resized !== bitmap) {
                    bitmap.recycle()
                }

                return resized
            }

            return bitmap

        } catch (e: Exception) {
            e.printStackTrace()
            return null
        }
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences
    ) {
        appWidgetIds.forEach { widgetId ->

            val views = RemoteViews(
                context.packageName,
                R.layout.usly_widget
            )

            val days = widgetData.getString("relationshipDays", "0") ?: "0"
            val streak = widgetData.getString("photoStreak", "0") ?: "0"
            val photoPath = widgetData.getString("photoPath", "") ?: ""
            val emptyText = widgetData.getString("emptyText", "Wasze zdjęcia pojawią się tutaj") ?: "Wasze zdjęcia pojawią się tutaj"

            views.setTextViewText(
                R.id.widget_relationship_days,
                "$days dni razem"
            )

            views.setTextViewText(
                R.id.widget_streak,
                "🔥 $streak dni"
            )

            views.setTextViewText(
                R.id.widget_empty,
                emptyText
            )

            if (photoPath.isNotBlank()) {
                val bitmap = loadWidgetBitmap(photoPath)

                if (bitmap != null) {
                    views.setImageViewBitmap(
                        R.id.widget_photo,
                        bitmap
                    )

                    views.setViewVisibility(
                        R.id.widget_photo,
                        View.VISIBLE
                    )

                    views.setViewVisibility(
                        R.id.widget_empty,
                        View.GONE
                    )
                } else {
                    views.setViewVisibility(
                        R.id.widget_photo,
                        View.GONE
                    )

                    views.setViewVisibility(
                        R.id.widget_empty,
                        View.VISIBLE
                    )
                }
            } else {
                views.setViewVisibility(
                    R.id.widget_photo,
                    View.GONE
                )

                views.setViewVisibility(
                    R.id.widget_empty,
                    View.VISIBLE
                )
            }

            val pendingIntent = HomeWidgetLaunchIntent.getActivity(
                context,
                MainActivity::class.java
            )

            views.setOnClickPendingIntent(
                R.id.widget_root,
                pendingIntent
            )

            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }
}
