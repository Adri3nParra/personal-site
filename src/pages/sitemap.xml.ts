import type { APIRoute } from 'astro';
import { getCollection } from 'astro:content';
import { articleUrl, localeFromId, tagSlug } from '../lib/site';

export const GET: APIRoute = async ({ site }) => {
  const articles = await getCollection('articles', ({ data }) => !data.draft);
  const paths = new Set(['/','/about/','/experience/','/articles/','/contact/','/tags/','/en/','/en/about/','/en/experience/','/en/articles/','/en/contact/','/en/tags/']);
  articles.forEach((article) => {
    const locale = localeFromId(article.id);
    paths.add(articleUrl(article));
    article.data.tags.forEach((tag) => paths.add(`${locale === 'en' ? '/en' : ''}/tags/${tagSlug(tag)}/`));
  });
  const urls = [...paths].sort().map((path) => `<url><loc>${new URL(path, site).href}</loc></url>`).join('');
  return new Response(`<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">${urls}</urlset>`, { headers: { 'Content-Type': 'application/xml; charset=utf-8' } });
};
