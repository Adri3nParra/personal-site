import { defineCollection } from 'astro:content';
import { z } from 'astro/zod';
import { glob } from 'astro/loaders';

const articles = defineCollection({
  loader: glob({
    pattern: '**/index{,.en}.md',
    base: './content/articles',
  }),
  schema: z.object({
    title: z.string(),
    date: z.coerce.date(),
    draft: z.boolean().default(false),
    summary: z.string(),
    tags: z.array(z.string()).default([]),
  }),
});

export const collections = { articles };
