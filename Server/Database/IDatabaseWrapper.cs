using Server.Base;
using Server.DataTransfer;
using Server.Elements;

namespace Server.Database
{
    public interface IDatabaseWrapper
    {
        public string GetNamingConvention(ElementType type, string elementName);
        public long SendMessageToChannelFromSender(string sender, string receiver, string message);
        public long SendServerMessageToChannel(ServerMessageType type, string channelName, string message);
        public bool GetElementFromDatabase<T>(string name, ElementType type, out T element);
        public bool AddElementToDatabase<T>(GameElement element);
        public void Subscribe<T>(GameElement element, ConnectionToClient connection);
    }
}