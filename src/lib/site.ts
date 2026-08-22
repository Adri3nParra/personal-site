import type { CollectionEntry } from 'astro:content';

export type Locale = 'fr' | 'en';
export type Article = CollectionEntry<'articles'>;

export const site = {
  name: 'Adrien PARRA',
  role: {
    fr: 'Platform Engineer',
    en: 'Platform Engineer',
  },
  description: {
    fr: 'Platform Engineer · Architecture cloud-native · Kubernetes · AWS · GitOps · Linux',
    en: 'Platform Engineer · Cloud-native architecture · Kubernetes · AWS · GitOps · Linux',
  },
  social: {
    github: 'https://github.com/Adri3nParra',
    linkedin: 'https://www.linkedin.com/in/adrien-parra-5473a0159/',
  },
} as const;

export const copy = {
  fr: {
    nav: { about: 'À propos', experience: 'Expérience', articles: 'Articles', contact: 'Contact' },
    menu: 'Ouvrir le menu', closeMenu: 'Fermer le menu', theme: 'Changer de thème',
    language: 'English', read: 'Lire l’article', allArticles: 'Tous les articles',
    published: 'Publié le', contents: 'Sommaire', tags: 'Sujets', back: 'Retour aux articles',
    footer: 'Conçu avec Astro. Déployé sur Scaleway.', noArticles: 'Aucun article pour le moment.',
  },
  en: {
    nav: { about: 'About', experience: 'Experience', articles: 'Articles', contact: 'Contact' },
    menu: 'Open menu', closeMenu: 'Close menu', theme: 'Switch theme',
    language: 'Français', read: 'Read article', allArticles: 'All articles',
    published: 'Published on', contents: 'On this page', tags: 'Topics', back: 'Back to articles',
    footer: 'Built with Astro. Deployed on Scaleway.', noArticles: 'No articles yet.',
  },
} as const;

export function localeFromId(id: string): Locale {
  return id.endsWith('.en.md') || id.endsWith('.en') || id.endsWith('/indexen') ? 'en' : 'fr';
}

export function slugFromId(id: string): string {
  return id.split('/')[0];
}

export function articleUrl(article: Article): string {
  const locale = localeFromId(article.id);
  return `${locale === 'en' ? '/en' : ''}/articles/${slugFromId(article.id)}/`;
}

export function tagSlug(tag: string): string {
  return tag
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .replace(/&/g, 'and')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '');
}

export function tagUrl(tag: string, locale: Locale): string {
  return `${locale === 'en' ? '/en' : ''}/tags/${tagSlug(tag)}/`;
}

export function formatDate(date: Date, locale: Locale): string {
  return new Intl.DateTimeFormat(locale === 'fr' ? 'fr-FR' : 'en-GB', {
    day: 'numeric', month: 'long', year: 'numeric', timeZone: 'UTC',
  }).format(date);
}

export function alternatePath(pathname: string, locale: Locale): string {
  if (pathname === '/404' || pathname.includes('/404/')) return locale === 'fr' ? '/en/' : '/';
  if (pathname.includes('/tags/')) return locale === 'fr' ? '/en/tags/' : '/tags/';
  if (locale === 'fr') return `/en${pathname === '/' ? '/' : pathname}`;
  const frenchPath = pathname.replace(/^\/en(?=\/|$)/, '');
  return frenchPath || '/';
}
