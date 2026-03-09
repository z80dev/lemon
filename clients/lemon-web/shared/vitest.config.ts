import { defineConfig, mergeConfig } from 'vitest/config';
import { baseVitestConfig } from '../../vitest.base.js';

export default mergeConfig(baseVitestConfig, defineConfig({}));
