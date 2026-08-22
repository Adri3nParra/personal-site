import { getCollection } from 'astro:content';
import { articleUrl, localeFromId, site, type Locale } from './site';

const escapeXml = (value: string) => value.replace(/[<>&'\"]/g, (char) => ({
  '<': '&lt;', '>': '&gt;', '&': '&amp;', "'": '&apos;', '"': '&quot;',
}[char] ?? char));

export async function createFeed(locale: Locale, baseUrl: URL): Promise<Response> {
  const articles = (await getCollection('articles', ({ data }) => !data.draft))
    .filter((article) => localeFromId(article.id) === locale)
    .sort((a, b) => b.data.date.valueOf() - a.data.date.valueOf());
  const title = locale === 'fr' ? 'Adrien PARRA — Articles' : 'Adrien PARRA — Articles (English)';
  const description = site.description[locale];
  const home = new URL(locale === 'en' ? '/en/' : '/', baseUrl).href;
  const items = articles.map((article) => {
    const url = new URL(articleUrl(article), baseUrl).href;
    return `<item><title>${escapeXml(article.data.title)}</title><link>${url}</link><guid>${url}</guid><pubDate>${article.data.date.toUTCString()}</pubDate><description>${escapeXml(article.data.summary)}</description></item>`;
  }).join('');
  const xml = `<?xml version="1.0" encoding="UTF-8"?><rss version="2.0"><channel><title>${escapeXml(title)}</title><link>${home}</link><description>${escapeXml(description)}</description><language>${locale}</language>${items}</channel></rss>`;
  return new Response(xml, { headers: { 'Content-Type': 'application/rss+xml; charset=utf-8' } });
}
