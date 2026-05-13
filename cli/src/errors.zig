pub const CliError = error{
    UserError,
    MissingArgument,
    InvalidArgument,
    InvalidReference,
    NotFound,
    AmbiguousReference,
    Unauthorized,
    InvalidEvent,
    GitFailed,
    ConfigNotFound,
    ConfigInvalid,
    NotGitRepository,
    SqliteFailed,
};

pub fn isUserError(err: anyerror) bool {
    return switch (err) {
        CliError.UserError,
        CliError.MissingArgument,
        CliError.InvalidArgument,
        CliError.InvalidReference,
        CliError.NotFound,
        CliError.AmbiguousReference,
        CliError.Unauthorized,
        CliError.InvalidEvent,
        => true,
        else => false,
    };
}

pub fn isReported(err: anyerror) bool {
    return isUserError(err) or switch (err) {
        CliError.GitFailed,
        CliError.SqliteFailed,
        => true,
        else => false,
    };
}
