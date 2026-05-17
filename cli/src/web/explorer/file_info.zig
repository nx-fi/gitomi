const std = @import("std");
const shared = @import("../shared.zig");
const source_stats = @import("../source_stats.zig");
const model = @import("model.zig");

const Allocator = std.mem.Allocator;
const MediaKind = model.MediaKind;
const TreeEntry = model.TreeEntry;
const DeviconMapping = model.DeviconMapping;
const appendFmt = shared.appendFmt;
const appendTemplate = shared.appendTemplate;

fn baseName(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

const exact_file_devicons = [_]DeviconMapping{
    .{ .key = ".babelrc", .class = "devicon-babel-plain" },
    .{ .key = ".babelrc.cjs", .class = "devicon-babel-plain" },
    .{ .key = ".babelrc.js", .class = "devicon-babel-plain" },
    .{ .key = ".babelrc.json", .class = "devicon-babel-plain" },
    .{ .key = ".babelrc.mjs", .class = "devicon-babel-plain" },
    .{ .key = ".dockerignore", .class = "devicon-docker-plain" },
    .{ .key = ".eslintignore", .class = "devicon-eslint-plain" },
    .{ .key = ".eslintrc", .class = "devicon-eslint-plain" },
    .{ .key = ".eslintrc.cjs", .class = "devicon-eslint-plain" },
    .{ .key = ".eslintrc.js", .class = "devicon-eslint-plain" },
    .{ .key = ".eslintrc.json", .class = "devicon-eslint-plain" },
    .{ .key = ".eslintrc.mjs", .class = "devicon-eslint-plain" },
    .{ .key = ".eslintrc.yaml", .class = "devicon-eslint-plain" },
    .{ .key = ".eslintrc.yml", .class = "devicon-eslint-plain" },
    .{ .key = ".firebaserc", .class = "devicon-firebase-plain" },
    .{ .key = ".git-blame-ignore-revs", .class = "devicon-git-plain" },
    .{ .key = ".gitattributes", .class = "devicon-git-plain" },
    .{ .key = ".gitconfig", .class = "devicon-git-plain" },
    .{ .key = ".gitignore", .class = "devicon-git-plain" },
    .{ .key = ".gitkeep", .class = "devicon-git-plain" },
    .{ .key = ".gitmodules", .class = "devicon-git-plain" },
    .{ .key = ".mailmap", .class = "devicon-git-plain" },
    .{ .key = ".node-version", .class = "devicon-nodejs-plain" },
    .{ .key = ".npmignore", .class = "devicon-npm-plain" },
    .{ .key = ".npmrc", .class = "devicon-npm-plain" },
    .{ .key = ".nvmrc", .class = "devicon-nodejs-plain" },
    .{ .key = ".pnpmfile.cjs", .class = "devicon-pnpm-plain" },
    .{ .key = ".postcssrc", .class = "devicon-postcss-original" },
    .{ .key = ".postcssrc.cjs", .class = "devicon-postcss-original" },
    .{ .key = ".postcssrc.js", .class = "devicon-postcss-original" },
    .{ .key = ".postcssrc.json", .class = "devicon-postcss-original" },
    .{ .key = ".postcssrc.mjs", .class = "devicon-postcss-original" },
    .{ .key = ".postcssrc.yaml", .class = "devicon-postcss-original" },
    .{ .key = ".postcssrc.yml", .class = "devicon-postcss-original" },
    .{ .key = ".python-version", .class = "devicon-python-plain" },
    .{ .key = ".ruby-gemset", .class = "devicon-ruby-plain" },
    .{ .key = ".ruby-version", .class = "devicon-ruby-plain" },
    .{ .key = ".terraform.lock.hcl", .class = "devicon-terraform-plain" },
    .{ .key = ".terraformrc", .class = "devicon-terraform-plain" },
    .{ .key = ".travis.yml", .class = "devicon-travis-plain" },
    .{ .key = ".yarnrc", .class = "devicon-yarn-original" },
    .{ .key = ".yarnrc.yml", .class = "devicon-yarn-original" },
    .{ .key = "angular.json", .class = "devicon-angular-plain" },
    .{ .key = "ansible.cfg", .class = "devicon-ansible-plain" },
    .{ .key = "artisan", .class = "devicon-laravel-original" },
    .{ .key = "azure-pipelines.yaml", .class = "devicon-azuredevops-plain" },
    .{ .key = "azure-pipelines.yml", .class = "devicon-azuredevops-plain" },
    .{ .key = "biome.json", .class = "devicon-biome-original" },
    .{ .key = "biome.jsonc", .class = "devicon-biome-original" },
    .{ .key = "bitbucket-pipelines.yml", .class = "devicon-bitbucket-original" },
    .{ .key = "build.gradle", .class = "devicon-gradle-original" },
    .{ .key = "build.gradle.kts", .class = "devicon-gradle-original" },
    .{ .key = "build.sbt", .class = "devicon-scala-plain" },
    .{ .key = "bun.lock", .class = "devicon-bun-plain" },
    .{ .key = "bun.lockb", .class = "devicon-bun-plain" },
    .{ .key = "bunfig.toml", .class = "devicon-bun-plain" },
    .{ .key = "cabal.project", .class = "devicon-haskell-plain" },
    .{ .key = "cargo.lock", .class = "devicon-rust-original" },
    .{ .key = "cargo.toml", .class = "devicon-rust-original" },
    .{ .key = "chart.lock", .class = "devicon-helm-original" },
    .{ .key = "chart.yaml", .class = "devicon-helm-original" },
    .{ .key = "circle.yml", .class = "devicon-circleci-plain" },
    .{ .key = "cloudbuild.yaml", .class = "devicon-googlecloud-plain" },
    .{ .key = "cloudbuild.yml", .class = "devicon-googlecloud-plain" },
    .{ .key = "cmakelists.txt", .class = "devicon-cmake-plain" },
    .{ .key = "cmakepresets.json", .class = "devicon-cmake-plain" },
    .{ .key = "cmakeuserpresets.json", .class = "devicon-cmake-plain" },
    .{ .key = "codeowners", .class = "devicon-github-original" },
    .{ .key = "compose.yaml", .class = "devicon-docker-plain" },
    .{ .key = "compose.yml", .class = "devicon-docker-plain" },
    .{ .key = "composer.json", .class = "devicon-composer-line" },
    .{ .key = "composer.lock", .class = "devicon-composer-line" },
    .{ .key = "constraints.txt", .class = "devicon-python-plain" },
    .{ .key = "docker-compose.yaml", .class = "devicon-docker-plain" },
    .{ .key = "docker-compose.yml", .class = "devicon-docker-plain" },
    .{ .key = "docker-bake.hcl", .class = "devicon-docker-plain" },
    .{ .key = "dockerfile", .class = "devicon-docker-plain" },
    .{ .key = "deno.json", .class = "devicon-denojs-original" },
    .{ .key = "deno.jsonc", .class = "devicon-denojs-original" },
    .{ .key = "deno.lock", .class = "devicon-denojs-original" },
    .{ .key = "dependabot.yaml", .class = "devicon-github-original" },
    .{ .key = "dependabot.yml", .class = "devicon-github-original" },
    .{ .key = "elm.json", .class = "devicon-elm-plain" },
    .{ .key = "ember-cli-build.js", .class = "devicon-ember-plain" },
    .{ .key = "environment.yaml", .class = "devicon-anaconda-original" },
    .{ .key = "environment.yml", .class = "devicon-anaconda-original" },
    .{ .key = "firebase.json", .class = "devicon-firebase-plain" },
    .{ .key = "flake.lock", .class = "devicon-nixos-plain" },
    .{ .key = "funding.yml", .class = "devicon-github-original" },
    .{ .key = "gemfile", .class = "devicon-ruby-plain" },
    .{ .key = "gemfile.lock", .class = "devicon-ruby-plain" },
    .{ .key = "go.mod", .class = "devicon-go-plain" },
    .{ .key = "go.sum", .class = "devicon-go-plain" },
    .{ .key = "go.work", .class = "devicon-go-plain" },
    .{ .key = "go.work.sum", .class = "devicon-go-plain" },
    .{ .key = "gradle.properties", .class = "devicon-gradle-original" },
    .{ .key = "gradlew", .class = "devicon-gradle-original" },
    .{ .key = "gradlew.bat", .class = "devicon-gradle-original" },
    .{ .key = "helmfile.yaml", .class = "devicon-helm-original" },
    .{ .key = "helmfile.yml", .class = "devicon-helm-original" },
    .{ .key = "httpd.conf", .class = "devicon-apache-plain" },
    .{ .key = "jenkinsfile", .class = "devicon-jenkins-plain" },
    .{ .key = "jsconfig.json", .class = "devicon-javascript-plain" },
    .{ .key = "kustomization.yaml", .class = "devicon-kubernetes-plain" },
    .{ .key = "kustomization.yml", .class = "devicon-kubernetes-plain" },
    .{ .key = "manage.py", .class = "devicon-django-plain" },
    .{ .key = "mix.exs", .class = "devicon-elixir-plain" },
    .{ .key = "mix.lock", .class = "devicon-elixir-plain" },
    .{ .key = "mvnw", .class = "devicon-maven-plain" },
    .{ .key = "mvnw.cmd", .class = "devicon-maven-plain" },
    .{ .key = "netlify.toml", .class = "devicon-netlify-plain" },
    .{ .key = "nginx.conf", .class = "devicon-nginx-original" },
    .{ .key = "npm-shrinkwrap.json", .class = "devicon-npm-plain" },
    .{ .key = "package-lock.json", .class = "devicon-npm-plain" },
    .{ .key = "package.json", .class = "devicon-npm-plain" },
    .{ .key = "package.swift", .class = "devicon-swift-plain" },
    .{ .key = "pipfile", .class = "devicon-python-plain" },
    .{ .key = "pipfile.lock", .class = "devicon-python-plain" },
    .{ .key = "pnpm-lock.yaml", .class = "devicon-pnpm-plain" },
    .{ .key = "pnpm-workspace.yaml", .class = "devicon-pnpm-plain" },
    .{ .key = "podfile", .class = "devicon-xcode-plain" },
    .{ .key = "podfile.lock", .class = "devicon-xcode-plain" },
    .{ .key = "poetry.lock", .class = "devicon-poetry-plain" },
    .{ .key = "pom.xml", .class = "devicon-maven-plain" },
    .{ .key = "procfile", .class = "devicon-heroku-original" },
    .{ .key = "pubspec.lock", .class = "devicon-dart-plain" },
    .{ .key = "pubspec.yaml", .class = "devicon-dart-plain" },
    .{ .key = "pulumi.yaml", .class = "devicon-pulumi-plain" },
    .{ .key = "pulumi.yml", .class = "devicon-pulumi-plain" },
    .{ .key = "pyproject.toml", .class = "devicon-python-plain" },
    .{ .key = "pytest.ini", .class = "devicon-pytest-plain" },
    .{ .key = "rakefile", .class = "devicon-ruby-plain" },
    .{ .key = "rebar.config", .class = "devicon-erlang-plain" },
    .{ .key = "rebar.lock", .class = "devicon-erlang-plain" },
    .{ .key = "requirements.txt", .class = "devicon-python-plain" },
    .{ .key = "rust-toolchain", .class = "devicon-rust-original" },
    .{ .key = "rust-toolchain.toml", .class = "devicon-rust-original" },
    .{ .key = "rustfmt.toml", .class = "devicon-rust-original" },
    .{ .key = "schema.prisma", .class = "devicon-prisma-original" },
    .{ .key = "settings.gradle", .class = "devicon-gradle-original" },
    .{ .key = "settings.gradle.kts", .class = "devicon-gradle-original" },
    .{ .key = "setup.cfg", .class = "devicon-python-plain" },
    .{ .key = "setup.py", .class = "devicon-python-plain" },
    .{ .key = "stack.yaml", .class = "devicon-haskell-plain" },
    .{ .key = "symfony.lock", .class = "devicon-symfony-original" },
    .{ .key = "terraform.rc", .class = "devicon-terraform-plain" },
    .{ .key = "tox.ini", .class = "devicon-python-plain" },
    .{ .key = "tsconfig.base.json", .class = "devicon-typescript-plain" },
    .{ .key = "tsconfig.json", .class = "devicon-typescript-plain" },
    .{ .key = "uv.lock", .class = "devicon-python-plain" },
    .{ .key = "vagrantfile", .class = "devicon-vagrant-plain" },
    .{ .key = "vercel.json", .class = "devicon-vercel-original" },
    .{ .key = "wrangler.toml", .class = "devicon-cloudflareworkers-plain" },
    .{ .key = "yarn.lock", .class = "devicon-yarn-original" },
};

const base_prefix_devicons = [_]DeviconMapping{
    .{ .key = ".babelrc.", .class = "devicon-babel-plain" },
    .{ .key = ".eslintrc.", .class = "devicon-eslint-plain" },
    .{ .key = ".postcssrc.", .class = "devicon-postcss-original" },
    .{ .key = "astro.config.", .class = "devicon-astro-plain" },
    .{ .key = "babel.config.", .class = "devicon-babel-plain" },
    .{ .key = "cypress.config.", .class = "devicon-cypressio-plain" },
    .{ .key = "dockerfile.", .class = "devicon-docker-plain" },
    .{ .key = "eslint.config.", .class = "devicon-eslint-plain" },
    .{ .key = "gatsby-browser.", .class = "devicon-gatsby-original" },
    .{ .key = "gatsby-config.", .class = "devicon-gatsby-original" },
    .{ .key = "gatsby-node.", .class = "devicon-gatsby-original" },
    .{ .key = "gatsby-ssr.", .class = "devicon-gatsby-original" },
    .{ .key = "jest.config.", .class = "devicon-jest-plain" },
    .{ .key = "jest.setup.", .class = "devicon-jest-plain" },
    .{ .key = "karma.conf.", .class = "devicon-karma-plain" },
    .{ .key = "knexfile.", .class = "devicon-knexjs-original" },
    .{ .key = "next.config.", .class = "devicon-nextjs-plain" },
    .{ .key = "nuxt.config.", .class = "devicon-nuxt-original" },
    .{ .key = "openapi.", .class = "devicon-openapi-plain" },
    .{ .key = "playwright.config.", .class = "devicon-playwright-plain" },
    .{ .key = "postcss.config.", .class = "devicon-postcss-original" },
    .{ .key = "pulumi.", .class = "devicon-pulumi-plain" },
    .{ .key = "remix.config.", .class = "devicon-remix-original" },
    .{ .key = "rollup.config.", .class = "devicon-rollup-plain" },
    .{ .key = "sequelize.config.", .class = "devicon-sequelize-plain" },
    .{ .key = "svelte.config.", .class = "devicon-svelte-plain" },
    .{ .key = "swagger.", .class = "devicon-swagger-plain" },
    .{ .key = "tailwind.config.", .class = "devicon-tailwindcss-original" },
    .{ .key = "vite.config.", .class = "devicon-vite-original" },
    .{ .key = "vitest.config.", .class = "devicon-vitest-plain" },
    .{ .key = "vue.config.", .class = "devicon-vuejs-plain" },
    .{ .key = "webpack.config.", .class = "devicon-webpack-plain" },
};

const base_suffix_devicons = [_]DeviconMapping{
    .{ .key = ".astro", .class = "devicon-astro-plain" },
    .{ .key = ".bazel", .class = "devicon-bazel-plain" },
    .{ .key = ".bzl", .class = "devicon-bazel-plain" },
    .{ .key = ".cabal", .class = "devicon-haskell-plain" },
    .{ .key = ".csproj", .class = "devicon-dot-net-plain" },
    .{ .key = ".fsproj", .class = "devicon-dot-net-plain" },
    .{ .key = ".gradle", .class = "devicon-gradle-original" },
    .{ .key = ".gradle.kts", .class = "devicon-gradle-original" },
    .{ .key = ".ipynb", .class = "devicon-jupyter-plain" },
    .{ .key = ".nomad", .class = "devicon-nomad-original" },
    .{ .key = ".nomad.hcl", .class = "devicon-nomad-original" },
    .{ .key = ".pbxproj", .class = "devicon-xcode-plain" },
    .{ .key = ".pkr.hcl", .class = "devicon-packer-plain" },
    .{ .key = ".prisma", .class = "devicon-prisma-original" },
    .{ .key = ".razor", .class = "devicon-blazor-original" },
    .{ .key = ".rproj", .class = "devicon-rstudio-plain" },
    .{ .key = ".sln", .class = "devicon-visualstudio-plain" },
    .{ .key = ".tf", .class = "devicon-terraform-plain" },
    .{ .key = ".tfstate", .class = "devicon-terraform-plain" },
    .{ .key = ".tfvars", .class = "devicon-terraform-plain" },
    .{ .key = ".vbproj", .class = "devicon-dot-net-plain" },
    .{ .key = ".vue", .class = "devicon-vuejs-plain" },
    .{ .key = ".xcconfig", .class = "devicon-xcode-plain" },
    .{ .key = ".zig.zon", .class = "devicon-zig-original" },
};

const language_devicons = [_]DeviconMapping{
    .{ .key = "apache", .class = "devicon-apache-plain" },
    .{ .key = "arduino", .class = "devicon-arduino-plain" },
    .{ .key = "awk", .class = "devicon-awk-plain-wordmark" },
    .{ .key = "bash", .class = "devicon-bash-plain" },
    .{ .key = "c", .class = "devicon-c-original" },
    .{ .key = "ceylon", .class = "devicon-ceylon-plain" },
    .{ .key = "clojure", .class = "devicon-clojure-plain" },
    .{ .key = "cmake", .class = "devicon-cmake-plain" },
    .{ .key = "coffeescript", .class = "devicon-coffeescript-original" },
    .{ .key = "cpp", .class = "devicon-cplusplus-plain" },
    .{ .key = "crystal", .class = "devicon-crystal-original" },
    .{ .key = "csharp", .class = "devicon-csharp-plain" },
    .{ .key = "css", .class = "devicon-css3-plain" },
    .{ .key = "dart", .class = "devicon-dart-plain" },
    .{ .key = "delphi", .class = "devicon-delphi-plain" },
    .{ .key = "django", .class = "devicon-django-plain" },
    .{ .key = "dockerfile", .class = "devicon-docker-plain" },
    .{ .key = "dos", .class = "devicon-msdos-plain" },
    .{ .key = "elixir", .class = "devicon-elixir-plain" },
    .{ .key = "elm", .class = "devicon-elm-plain" },
    .{ .key = "erlang", .class = "devicon-erlang-plain" },
    .{ .key = "fortran", .class = "devicon-fortran-original" },
    .{ .key = "fsharp", .class = "devicon-fsharp-plain" },
    .{ .key = "gherkin", .class = "devicon-cucumber-plain" },
    .{ .key = "go", .class = "devicon-go-plain" },
    .{ .key = "gradle", .class = "devicon-gradle-original" },
    .{ .key = "graphql", .class = "devicon-graphql-plain" },
    .{ .key = "groovy", .class = "devicon-groovy-plain" },
    .{ .key = "handlebars", .class = "devicon-handlebars-original" },
    .{ .key = "haskell", .class = "devicon-haskell-plain" },
    .{ .key = "haxe", .class = "devicon-haxe-plain" },
    .{ .key = "html", .class = "devicon-html5-plain" },
    .{ .key = "java", .class = "devicon-java-plain" },
    .{ .key = "javascript", .class = "devicon-javascript-plain" },
    .{ .key = "json", .class = "devicon-json-plain" },
    .{ .key = "julia", .class = "devicon-julia-plain" },
    .{ .key = "kotlin", .class = "devicon-kotlin-plain" },
    .{ .key = "latex", .class = "devicon-latex-original" },
    .{ .key = "less", .class = "devicon-less-plain-wordmark" },
    .{ .key = "llvm", .class = "devicon-llvm-plain" },
    .{ .key = "lua", .class = "devicon-lua-plain" },
    .{ .key = "markdown", .class = "devicon-markdown-original" },
    .{ .key = "matlab", .class = "devicon-matlab-plain" },
    .{ .key = "nginx", .class = "devicon-nginx-original" },
    .{ .key = "nim", .class = "devicon-nim-plain" },
    .{ .key = "nix", .class = "devicon-nixos-plain" },
    .{ .key = "objectivec", .class = "devicon-objectivec-plain" },
    .{ .key = "ocaml", .class = "devicon-ocaml-plain" },
    .{ .key = "perl", .class = "devicon-perl-plain" },
    .{ .key = "pgsql", .class = "devicon-postgresql-plain" },
    .{ .key = "php", .class = "devicon-php-plain" },
    .{ .key = "powershell", .class = "devicon-powershell-plain" },
    .{ .key = "processing", .class = "devicon-processing-plain" },
    .{ .key = "prolog", .class = "devicon-prolog-plain" },
    .{ .key = "python", .class = "devicon-python-plain" },
    .{ .key = "r", .class = "devicon-r-plain" },
    .{ .key = "ruby", .class = "devicon-ruby-plain" },
    .{ .key = "rust", .class = "devicon-rust-original" },
    .{ .key = "scala", .class = "devicon-scala-plain" },
    .{ .key = "scss", .class = "devicon-sass-original" },
    .{ .key = "shell", .class = "devicon-bash-plain" },
    .{ .key = "solidity", .class = "devicon-solidity-plain" },
    .{ .key = "stata", .class = "devicon-stata-original-wordmark" },
    .{ .key = "stylus", .class = "devicon-stylus-original" },
    .{ .key = "svelte", .class = "devicon-svelte-plain" },
    .{ .key = "swift", .class = "devicon-swift-plain" },
    .{ .key = "typescript", .class = "devicon-typescript-plain" },
    .{ .key = "vala", .class = "devicon-vala-plain" },
    .{ .key = "vbnet", .class = "devicon-visualbasic-plain" },
    .{ .key = "vim", .class = "devicon-vim-plain" },
    .{ .key = "wasm", .class = "devicon-wasm-original" },
    .{ .key = "xml", .class = "devicon-xml-plain" },
    .{ .key = "yaml", .class = "devicon-yaml-plain" },
    .{ .key = "zig", .class = "devicon-zig-original" },
};

pub fn appendFileIcon(buf: *std.ArrayList(u8), allocator: Allocator, path: []const u8, kind: []const u8) !void {
    if (deviconClassForPath(path, kind)) |class| {
        try appendTemplate(buf, allocator,
            \\<i class="file-icon devicon-icon {class}" aria-hidden="true"></i>
        , .{ .class = class });
        return;
    }

    try appendTemplate(buf, allocator,
        \\<span class="file-icon {class}" aria-hidden="true"></span>
    , .{ .class = fileIconClass(path, kind) });
}

pub fn deviconClassForPath(path: []const u8, kind: []const u8) ?[]const u8 {
    if (!std.mem.eql(u8, kind, "blob")) return null;
    if (mediaKindForPath(path) != null) return null;

    const base = baseName(path);
    if (deviconClassForExactBase(base)) |class| return class;
    if (deviconClassForPathPattern(path, base)) |class| return class;
    if (deviconClassForBasePrefix(base)) |class| return class;
    if (deviconClassForBaseSuffix(base)) |class| return class;

    const language = languageForPath(path);
    return deviconClassForLanguage(language);
}

pub fn deviconClassForExactBase(base: []const u8) ?[]const u8 {
    return deviconClassFromMappings(base, &exact_file_devicons);
}

pub fn deviconClassForPathPattern(path: []const u8, base: []const u8) ?[]const u8 {
    if (std.ascii.startsWithIgnoreCase(path, ".github/workflows/") and isYamlPath(path)) return "devicon-githubactions-plain";
    if (std.ascii.startsWithIgnoreCase(path, ".github/")) return "devicon-github-original";
    if (std.ascii.startsWithIgnoreCase(path, ".gitlab/")) return "devicon-gitlab-plain";
    if (std.ascii.startsWithIgnoreCase(path, ".circleci/")) return "devicon-circleci-plain";
    if (std.ascii.startsWithIgnoreCase(path, ".devcontainer/")) return "devicon-docker-plain";
    if (std.ascii.startsWithIgnoreCase(path, ".vscode/")) return "devicon-vscode-plain";
    if (std.ascii.startsWithIgnoreCase(path, ".mvn/")) return "devicon-maven-plain";
    if (std.ascii.startsWithIgnoreCase(path, ".cargo/")) return "devicon-rust-original";
    if (std.ascii.startsWithIgnoreCase(path, ".gradle/")) return "devicon-gradle-original";
    if (std.ascii.startsWithIgnoreCase(path, ".yarn/")) return "devicon-yarn-original";
    if (std.ascii.startsWithIgnoreCase(path, ".storybook/")) return "devicon-storybook-plain";
    if (std.ascii.startsWithIgnoreCase(path, "charts/") and std.ascii.eqlIgnoreCase(base, "values.yaml")) return "devicon-helm-original";
    if (std.ascii.startsWithIgnoreCase(path, "charts/") and std.ascii.eqlIgnoreCase(base, "values.yml")) return "devicon-helm-original";
    return null;
}

pub fn deviconClassForBasePrefix(base: []const u8) ?[]const u8 {
    for (base_prefix_devicons) |mapping| {
        if (std.ascii.startsWithIgnoreCase(base, mapping.key)) return mapping.class;
    }
    return null;
}

pub fn deviconClassForBaseSuffix(base: []const u8) ?[]const u8 {
    for (base_suffix_devicons) |mapping| {
        if (endsWithIgnoreCase(base, mapping.key)) return mapping.class;
    }
    return null;
}

pub fn deviconClassForLanguage(language: []const u8) ?[]const u8 {
    return deviconClassFromMappings(language, &language_devicons);
}

pub fn deviconClassFromMappings(value: []const u8, mappings: []const DeviconMapping) ?[]const u8 {
    for (mappings) |mapping| {
        if (std.ascii.eqlIgnoreCase(value, mapping.key)) return mapping.class;
    }
    return null;
}

pub fn isYamlPath(path: []const u8) bool {
    return endsWithIgnoreCase(path, ".yaml") or endsWithIgnoreCase(path, ".yml");
}

pub fn fileIconClass(path: []const u8, kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "tree")) return "dir";
    if (mediaKindForPath(path)) |media_kind| {
        return switch (media_kind) {
            .image => "file lang-img",
            .video => "file lang-video",
        };
    }
    const language = languageForPath(path);
    if (std.mem.eql(u8, language, "zig")) return "file lang-zig";
    if (std.mem.eql(u8, language, "javascript")) return "file lang-js";
    if (std.mem.eql(u8, language, "typescript")) return "file lang-ts";
    if (std.mem.eql(u8, language, "bash")) return "file lang-sh";
    if (std.mem.eql(u8, language, "json")) return "file lang-json";
    if (std.mem.eql(u8, language, "toml")) return "file lang-toml";
    if (std.mem.eql(u8, language, "yaml")) return "file lang-yaml";
    if (std.mem.eql(u8, language, "css")) return "file lang-css";
    if (std.mem.eql(u8, language, "html")) return "file lang-html";
    if (std.mem.eql(u8, language, "xml")) return "file lang-xml";
    if (std.mem.eql(u8, language, "sql")) return "file lang-sql";
    if (std.mem.eql(u8, language, "solidity")) return "file lang-sol";
    if (std.mem.eql(u8, language, "tla")) return "file lang-tla";
    if (std.mem.eql(u8, language, "rust")) return "file lang-rs";
    if (std.mem.eql(u8, language, "python")) return "file lang-py";
    if (std.mem.eql(u8, language, "markdown")) return "file lang-md";
    return "file";
}

test "fallback file icons are monotone" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendFileIcon(&buf, std.testing.allocator, "sigid.example.toml", "blob");
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "class=\"file-icon file lang-toml\"") != null);

    const css = @embedFile("../style.css");
    try std.testing.expect(std.mem.indexOf(u8, css, ".file-icon.lang-") == null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".file-icon.devicon-icon::before") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".file-icon[class*=\"lang-\"]::before") != null);
}

pub fn findReadme(entries: []const TreeEntry) ?[]const u8 {
    const names = [_][]const u8{ "README.md", "README", "Readme.md", "readme.md" };
    for (names) |wanted| {
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.kind, "blob") and std.mem.eql(u8, entry.name, wanted)) return entry.name;
        }
    }
    return null;
}

pub fn findLicense(entries: []const TreeEntry) ?[]const u8 {
    const names = [_][]const u8{ "LICENSE", "LICENSE.md", "LICENSE.txt", "COPYING", "COPYING.md", "COPYING.txt" };
    for (names) |wanted| {
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.kind, "blob") and std.ascii.eqlIgnoreCase(entry.name, wanted)) return entry.name;
        }
    }
    return null;
}

pub fn findAgents(entries: []const TreeEntry) ?[]const u8 {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.kind, "blob") and std.mem.eql(u8, entry.name, "AGENTS.md")) return entry.name;
    }
    return null;
}

pub fn licenseLabel(content: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(line, "MIT License")) return "MIT license";
        if (std.ascii.eqlIgnoreCase(line, "Apache License")) return "Apache license";
        if (line.len <= 80 and endsWithIgnoreCase(line, "License")) return line;
        break;
    }
    return "License";
}

pub fn isMarkdownPath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".md") or
        std.mem.endsWith(u8, path, ".markdown") or
        std.ascii.eqlIgnoreCase(baseName(path), "README");
}

pub fn mediaKindForPath(path: []const u8) ?MediaKind {
    if (isImagePath(path)) return .image;
    if (isVideoPath(path)) return .video;
    return null;
}

pub fn isPdfPath(path: []const u8) bool {
    return endsWithIgnoreCase(path, ".pdf");
}

pub fn isSvgPath(path: []const u8) bool {
    return endsWithIgnoreCase(path, ".svg");
}

pub fn isImagePath(path: []const u8) bool {
    return isSvgPath(path) or
        endsWithIgnoreCase(path, ".jpg") or
        endsWithIgnoreCase(path, ".jpeg") or
        endsWithIgnoreCase(path, ".png") or
        endsWithIgnoreCase(path, ".gif") or
        endsWithIgnoreCase(path, ".webp") or
        endsWithIgnoreCase(path, ".bmp") or
        endsWithIgnoreCase(path, ".ico");
}

pub fn isVideoPath(path: []const u8) bool {
    return endsWithIgnoreCase(path, ".mp4") or
        endsWithIgnoreCase(path, ".m4v") or
        endsWithIgnoreCase(path, ".webm") or
        endsWithIgnoreCase(path, ".ogv") or
        endsWithIgnoreCase(path, ".ogg") or
        endsWithIgnoreCase(path, ".mov");
}

pub fn contentTypeForPath(path: []const u8) []const u8 {
    if (isPdfPath(path)) return "application/pdf";
    if (endsWithIgnoreCase(path, ".svg")) return "image/svg+xml";
    if (endsWithIgnoreCase(path, ".jpg") or endsWithIgnoreCase(path, ".jpeg")) return "image/jpeg";
    if (endsWithIgnoreCase(path, ".png")) return "image/png";
    if (endsWithIgnoreCase(path, ".gif")) return "image/gif";
    if (endsWithIgnoreCase(path, ".webp")) return "image/webp";
    if (endsWithIgnoreCase(path, ".bmp")) return "image/bmp";
    if (endsWithIgnoreCase(path, ".ico")) return "image/x-icon";
    if (endsWithIgnoreCase(path, ".mp4") or endsWithIgnoreCase(path, ".m4v")) return "video/mp4";
    if (endsWithIgnoreCase(path, ".webm")) return "video/webm";
    if (endsWithIgnoreCase(path, ".ogv") or endsWithIgnoreCase(path, ".ogg")) return "video/ogg";
    if (endsWithIgnoreCase(path, ".mov")) return "video/quicktime";
    return "application/octet-stream";
}

pub fn languageForPath(path: []const u8) []const u8 {
    return source_stats.languageForPath(path);
}

pub fn normalizedPathOwned(allocator: Allocator, raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n/");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var parts = std.mem.splitScalar(u8, trimmed, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) return error.InvalidPath;
        if (out.items.len != 0) try out.append(allocator, '/');
        try out.appendSlice(allocator, part);
    }
    return out.toOwnedSlice(allocator);
}

pub fn queryValueOwned(allocator: Allocator, target: []const u8, wanted_key: []const u8) !?[]u8 {
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var pairs = std.mem.splitScalar(u8, target[query_start + 1 ..], '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const raw_key = pair[0..eq];
        const raw_value = if (eq < pair.len) pair[eq + 1 ..] else "";
        const key = try percentDecode(allocator, raw_key);
        defer allocator.free(key);
        if (!std.mem.eql(u8, key, wanted_key)) continue;
        return try percentDecode(allocator, raw_value);
    }
    return null;
}

pub fn formValueOwned(allocator: Allocator, body: []const u8, wanted_key: []const u8) !?[]u8 {
    var pairs = std.mem.splitScalar(u8, body, '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const raw_key = pair[0..eq];
        const raw_value = if (eq < pair.len) pair[eq + 1 ..] else "";
        const key = try percentDecode(allocator, raw_key);
        defer allocator.free(key);
        if (!std.mem.eql(u8, key, wanted_key)) continue;
        return try percentDecode(allocator, raw_value);
    }
    return null;
}

pub fn percentDecode(allocator: Allocator, value: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        switch (value[i]) {
            '+' => try buf.append(allocator, ' '),
            '%' => {
                if (i + 2 >= value.len) return error.InvalidUrlEncoding;
                const hi = hexValue(value[i + 1]) orelse return error.InvalidUrlEncoding;
                const lo = hexValue(value[i + 2]) orelse return error.InvalidUrlEncoding;
                try buf.append(allocator, (hi << 4) | lo);
                i += 2;
            },
            else => |c| try buf.append(allocator, c),
        }
    }

    return buf.toOwnedSlice(allocator);
}

pub fn appendSize(buf: *std.ArrayList(u8), allocator: Allocator, raw: []const u8) !void {
    const size = std.fmt.parseUnsigned(usize, raw, 10) catch {
        try appendTemplate(buf, allocator, "{raw}", .{ .raw = raw });
        return;
    };
    try appendByteSize(buf, allocator, size);
}

pub fn appendByteSize(buf: *std.ArrayList(u8), allocator: Allocator, size: usize) !void {
    if (size >= 1024 * 1024) {
        const whole = size / (1024 * 1024);
        const tenth = (size % (1024 * 1024)) * 10 / (1024 * 1024);
        try appendFmt(buf, allocator, "{d}.{d} MB", .{ whole, tenth });
    } else if (size >= 1024) {
        const whole = size / 1024;
        const tenth = (size % 1024) * 10 / 1024;
        try appendFmt(buf, allocator, "{d}.{d} KB", .{ whole, tenth });
    } else {
        try appendFmt(buf, allocator, "{d} B", .{size});
    }
}

pub fn containsNul(bytes: []const u8) bool {
    return std.mem.indexOfScalar(u8, bytes, 0) != null;
}

pub fn trimOwned(allocator: Allocator, raw: []u8) ![]u8 {
    defer allocator.free(raw);
    return allocator.dupe(u8, std.mem.trim(u8, raw, " \t\r\n"));
}

pub fn hexValue(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

pub fn endsWithIgnoreCase(value: []const u8, suffix: []const u8) bool {
    if (value.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(value[value.len - suffix.len ..], suffix);
}
