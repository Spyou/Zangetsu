package com.spyou.watch_app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class HlsAudioMasterTest {
    @Test fun noAudioGivesNoMaster() {
        assertNull(HlsAudioMaster.build("http://v/video.m3u8", emptyList()))
    }

    @Test fun plainFilesAreLeftAlone() {
        assertNull(HlsAudioMaster.build("http://v/ep1.MKV?x=1", listOf("http://a/jp.m3u8" to "Native")))
    }

    @Test fun pairsVideoWithEveryAudioTrackAndDefaultsTheFirst() {
        val m = HlsAudioMaster.build(
            "http://v/video.m3u8",
            listOf("http://a/jp.m3u8" to "Native", "http://a/en.m3u8" to "En\"glish"),
        )!!
        assertEquals(
            """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="Native",DEFAULT=YES,AUTOSELECT=YES,URI="http://a/jp.m3u8"
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="En'glish",DEFAULT=NO,AUTOSELECT=YES,URI="http://a/en.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=5000000,AUDIO="a"
            http://v/video.m3u8

            """.trimIndent(),
            m,
        )
    }
}
