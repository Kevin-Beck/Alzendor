using Newtonsoft.Json;

namespace AlzendorCore.Utilities
{
    public static class Objectifier
    {
        public static string Stringify(object thing)
        {
            return JsonConvert.SerializeObject(thing);
        }
        public static T DeStringify<T>(string s)
        {
            return JsonConvert.DeserializeObject<T>(s);
        }
    }
}
