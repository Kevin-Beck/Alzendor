using System;
using System.Collections.Generic;
using System.Text;

namespace Alzendor.Server
{
    public class ServerObject
    {
        public bool IsDirty { get; set; }

        protected List<string> subscribers;
        public void AddSubscriber(string subscriber)
        {
            subscribers.Add(subscriber);
        }
        public void RemoveSubscriber(string subscriber)
        {
            subscribers.Remove(subscriber);
        }
    }
}
