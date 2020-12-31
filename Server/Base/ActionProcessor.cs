using Server.Actions;
using log4net;
using System;
using System.Reflection;
using Server.Database;

namespace Server.Base
{
    public class ActionProcessor
    {
        private readonly static ILog logger = LogManager.GetLogger(MethodBase.GetCurrentMethod().DeclaringType);
        private IDatabaseWrapper storage;
        private ConnectionToClient connection;
        public ActionProcessor(IDatabaseWrapper storage, ConnectionToClient con)
        {
            this.storage = storage;
            connection = con;
        }
        
        public void Process(ActionObject curObject)
        {
            if (curObject == null)
            {
                return;
            }
            try
            {
                logger.Info($"Processing {curObject.ActionType}");
                curObject.ExecuteAction(storage, connection);
            }
            catch (Exception e)
            {
                logger.Error($"While processing ActionObject: {curObject.ToString()}\n\n{e.Message}\n\n{e.StackTrace}\n\n");
            }
        }
    }
}
