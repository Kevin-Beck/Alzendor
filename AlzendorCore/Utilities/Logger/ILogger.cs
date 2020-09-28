namespace Alzendor.Core.Utilities.Logger
{
    public interface ILogger
    {
        void Log(LogLevel level, string errorMessage);
    }
}
