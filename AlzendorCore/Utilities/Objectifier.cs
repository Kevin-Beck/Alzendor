using Newtonsoft.Json;
using System;
using System.Collections.Generic;
using System.Text;

namespace AlzendorCore.Utilities
{
    public static class Objectifier
    {
        public static string Stringify(object thing)
        {
            return JsonConvert.SerializeObject(thing);
        }
    }
}
