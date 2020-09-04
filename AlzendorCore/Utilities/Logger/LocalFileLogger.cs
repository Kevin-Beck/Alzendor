using System;
using System.IO;

namespace AlzendorCore.Utilities.Logger
{
    public class LocalFileLogger : ILogger
    {
        static int loggerCounter = 0;
        StreamWriter output;
        readonly string defaultFileName = $"Log{loggerCounter++} - {DateTime.Now.Hour}h{DateTime.Now.Minute}m{DateTime.Now.Second}s.txt";

        public LocalFileLogger(string path = "", string fileName = "")
        {
            try
            {
                if (path == null || path.Length < 1)
                {
                    Directory.CreateDirectory(Directory.GetCurrentDirectory() + "\\Logs");
                    path = Directory.GetCurrentDirectory() + "\\Logs";
                }
                if (fileName == null || fileName.Length < 1)
                {
                    fileName = defaultFileName;
                }
                output = new StreamWriter($"{path}\\{fileName}");
            }
            catch (Exception exception)
            {
                Console.WriteLine($"Logger Threw an Exception: {exception.Message}");
            }
        }
        public void Log(LogLevel level, string message)
        {
            try
            {
                Console.WriteLine($"Logger {level}: {message.Trim()}");
            }
            catch (Exception exception)
            {
                Console.WriteLine(exception.Message);
            }
            if (output != null)
            {
                output.WriteLine($"Logger {level}: {message}");
                output.Flush();
            }

        }
    }
}
