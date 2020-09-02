namespace AlzendorCore.Utilities.Logger
{
    public interface ILogger
    {
        void Log(LogLevel level, string errorMessage);
    }
}
