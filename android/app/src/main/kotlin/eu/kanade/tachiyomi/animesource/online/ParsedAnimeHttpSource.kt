package eu.kanade.tachiyomi.animesource.online

import eu.kanade.tachiyomi.animesource.model.AnimesPage
import eu.kanade.tachiyomi.animesource.model.Hoster
import eu.kanade.tachiyomi.animesource.model.SAnime
import eu.kanade.tachiyomi.animesource.model.SEpisode
import eu.kanade.tachiyomi.animesource.model.Video
import eu.kanade.tachiyomi.util.asJsoup
import okhttp3.Response
import org.jsoup.nodes.Document
import org.jsoup.nodes.Element

/**
 * A simple implementation for sources from a website using Jsoup, an HTML parser.
 */
@Suppress("unused")
abstract class ParsedAnimeHttpSource : AnimeHttpSource() {

    /**
     * Parses the response from the site and returns a [AnimesPage] object.
     *
     * @param response the response from the site.
     */
    override fun popularAnimeParse(response: Response): AnimesPage {
        val document = response.asJsoup()

        val animes = document.select(popularAnimeSelector()).map { element ->
            popularAnimeFromElement(element)
        }

        val hasNextPage = popularAnimeNextPageSelector()?.let { selector ->
            document.select(selector).first()
        } != null

        return AnimesPage(animes, hasNextPage)
    }

    /**
     * Returns the Jsoup selector that returns a list of [Element] corresponding to each anime.
     */
    protected abstract fun popularAnimeSelector(): String

    /**
     * Returns an anime from the given [element]. Most sites only show the title and the url, it's
     * totally fine to fill only those two values.
     *
     * @param element an element obtained from [popularAnimeSelector].
     */
    protected abstract fun popularAnimeFromElement(element: Element): SAnime

    /**
     * Returns the Jsoup selector that returns the <a> tag linking to the next page, or null if
     * there's no next page.
     */
    protected abstract fun popularAnimeNextPageSelector(): String?

    /**
     * Parses the response from the site and returns a [AnimesPage] object.
     *
     * @param response the response from the site.
     */
    override fun searchAnimeParse(response: Response): AnimesPage {
        val document = response.asJsoup()

        val animes = document.select(searchAnimeSelector()).map { element ->
            searchAnimeFromElement(element)
        }

        val hasNextPage = searchAnimeNextPageSelector()?.let { selector ->
            document.select(selector).first()
        } != null

        return AnimesPage(animes, hasNextPage)
    }

    /**
     * Returns the Jsoup selector that returns a list of [Element] corresponding to each anime.
     */
    protected abstract fun searchAnimeSelector(): String

    /**
     * Returns an anime from the given [element]. Most sites only show the title and the url, it's
     * totally fine to fill only those two values.
     *
     * @param element an element obtained from [searchAnimeSelector].
     */
    protected abstract fun searchAnimeFromElement(element: Element): SAnime

    /**
     * Returns the Jsoup selector that returns the <a> tag linking to the next page, or null if
     * there's no next page.
     */
    protected abstract fun searchAnimeNextPageSelector(): String?

    /**
     * Parses the response from the site and returns a [AnimesPage] object.
     *
     * @param response the response from the site.
     */
    override fun latestUpdatesParse(response: Response): AnimesPage {
        val document = response.asJsoup()

        val animes = document.select(latestUpdatesSelector()).map { element ->
            latestUpdatesFromElement(element)
        }

        val hasNextPage = latestUpdatesNextPageSelector()?.let { selector ->
            document.select(selector).first()
        } != null

        return AnimesPage(animes, hasNextPage)
    }

    /**
     * Returns the Jsoup selector that returns a list of [Element] corresponding to each anime.
     */
    protected abstract fun latestUpdatesSelector(): String

    /**
     * Returns an anime from the given [element]. Most sites only show the title and the url, it's
     * totally fine to fill only those two values.
     *
     * @param element an element obtained from [latestUpdatesSelector].
     */
    protected abstract fun latestUpdatesFromElement(element: Element): SAnime

    /**
     * Returns the Jsoup selector that returns the <a> tag linking to the next page, or null if
     * there's no next page.
     */
    protected abstract fun latestUpdatesNextPageSelector(): String?

    /**
     * Parses the response from the site and returns the details of an anime.
     *
     * @param response the response from the site.
     */
    override fun animeDetailsParse(response: Response): SAnime {
        return animeDetailsParse(response.asJsoup())
    }

    /**
     * Returns the details of the anime from the given [document].
     *
     * @param document the parsed document.
     */
    protected abstract fun animeDetailsParse(document: Document): SAnime

    /**
     * Parses the response from the site and returns a list of episodes.
     *
     * @param response the response from the site.
     */
    override fun episodeListParse(response: Response): List<SEpisode> {
        val document = response.asJsoup()
        return document.select(episodeListSelector()).map { episodeFromElement(it) }
    }

    /**
     * Returns the Jsoup selector that returns a list of [Element] corresponding to each episode.
     */
    protected abstract fun episodeListSelector(): String

    /**
     * Returns an episode from the given element.
     *
     * @param element an element obtained from [episodeListSelector].
     */
    protected abstract fun episodeFromElement(element: Element): SEpisode

    /**
     * Parses the response from the site and returns a list of seasons.
     *
     * Default: returns an empty list. Subclasses that support seasons should override
     * [seasonListSelector] and [seasonFromElement] (and [getSeasonList] in the parent to
     * make the HTTP request). Non-abstract selector/element methods are required for
     * mainstream v16 compatibility — extensions without season support must not be forced
     * to implement them.
     *
     * @since extensions-lib 16
     * @param response the response from the site.
     */
    override fun seasonListParse(response: Response): List<SAnime> {
        val selector = seasonListSelector()
        if (selector.isBlank()) return emptyList()
        val document = response.asJsoup()
        return document.select(selector).map { seasonFromElement(it) }
    }

    /**
     * Returns the Jsoup selector that returns a list of [Element] corresponding to each season.
     * Default is blank (no seasons). Override when [seasonListParse] is used.
     *
     * @since extensions-lib 16
     */
    protected open fun seasonListSelector(): String = ""

    /**
     * Returns a season from the given element.
     * Only called when [seasonListSelector] is non-blank. Override alongside [seasonListSelector].
     *
     * @since extensions-lib 16
     * @param element an element obtained from [seasonListSelector].
     */
    protected open fun seasonFromElement(element: Element): SAnime =
        throw UnsupportedOperationException("Override seasonFromElement when using seasonListSelector")

    /**
     * Parses the response from the site and returns the hoster list.
     *
     * Default: returns an empty list. Subclasses using the lib-16 Hoster API should override
     * [hosterListSelector] and [hosterFromElement]. Non-abstract for mainstream v16 compatibility
     * — extensions that resolve videos via the legacy [videoListParse(Response)] path do not
     * implement the Hoster API and must not be forced to provide these methods.
     *
     * @since extensions-lib 16
     * @param response the response from the site.
     * @return the list of hosters.
     */
    override fun hosterListParse(response: Response): List<Hoster> {
        val selector = hosterListSelector()
        if (selector.isBlank()) return emptyList()
        val document = response.asJsoup()
        return document.select(selector).map(::hosterFromElement)
    }

    /**
     * Returns the Jsoup selector for hoster elements.
     * Default is blank (no Hoster API). Override alongside [hosterFromElement].
     *
     * @since extensions-lib 16
     */
    protected open fun hosterListSelector(): String = ""

    /**
     * Returns a hoster from the given element.
     * Only called when [hosterListSelector] is non-blank.
     *
     * @since extensions-lib 16
     * @param element an element obtained from [hosterListSelector].
     */
    protected open fun hosterFromElement(element: Element): Hoster =
        throw UnsupportedOperationException("Override hosterFromElement when using hosterListSelector")

    /**
     * Parses the response from the site and returns the page list.
     *
     * @param response the response from the site.
     */
    override fun videoListParse(response: Response): List<Video> {
        val document = response.asJsoup()
        return document.select(videoListSelector()).map { videoFromElement(it) }
    }

    /**
     * Returns the Jsoup selector that returns a list of [Element] corresponding to each video.
     */
    protected abstract fun videoListSelector(): String

    /**
     * Returns a video from the given element.
     *
     * @param element an element obtained from [videoListSelector].
     */
    protected abstract fun videoFromElement(element: Element): Video

    /**
     * Parse the response from the site and returns the absolute url to the source video.
     *
     * @param response the response from the site.
     */
    override fun videoUrlParse(response: Response): String {
        return videoUrlParse(response.asJsoup())
    }

    /**
     * Returns the absolute url to the source image from the document.
     *
     * @param document the parsed document.
     */
    protected abstract fun videoUrlParse(document: Document): String
}
