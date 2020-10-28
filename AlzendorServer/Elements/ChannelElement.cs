using AlzendorServer.Elements;
using System.Collections.Generic;

namespace AlzendorServer.Elements
{
    public class ChannelElement : GameElement
    {
        public string ChannelName { get; set; }
        public string ChannelOwner { get; set; }
        public bool IsPrivate { get; set; } = true;
        public ChannelElement(string channelName, string channelCreator, bool isPrivate) : base()
        {
            ChannelName = channelName;
            ChannelOwner = channelCreator;
            IsPrivate = isPrivate;
        }
    }
}
