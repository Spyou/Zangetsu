/*
 * Copyright 2015 Javier Tomás
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Adapted from the Aniyomi project (https://github.com/aniyomiorg/aniyomi)
 * for host-side injection into the Aniyomi extension runtime.
 */
package com.spyou.watch_app.aniyomi

import android.content.SharedPreferences

/**
 * Minimal host-side [SourcePreferences] injected into the Aniyomi extension graph.
 *
 * Aniyomi extensions resolve this type via `Injekt.get<SourcePreferences>()` when
 * they need a preferences store scoped to their source. The underlying
 * [SharedPreferences] is the same store used by the host for all Aniyomi state
 * (`"zangetsu_aniyomi"`); individual source keys are namespaced by source id in
 * the extension itself (via [eu.kanade.tachiyomi.animesource.utils.preferencesKey]).
 */
class SourcePreferences(val sharedPreferences: SharedPreferences)
