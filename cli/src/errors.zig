pub const CliError = error{
    UserError,
    GitFailed,
    ConfigNotFound,
    ConfigInvalid,
    NotGitRepository,
    SqliteFailed,
};
